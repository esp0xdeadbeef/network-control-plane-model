{ common }:

{
  endpointBindings ? { },
  transitInterfaces,
  relations ? [ ],
  services ? [ ],
  trafficTypeMatches ? { },
  overlayNames ? [ ],
  siteRuntimeOriginSourcePrefixes ? [ ],
  egressEnabled ? true,
}:

let
  endpointContext = import ./endpoint-context.nix { inherit common; } {
    inherit endpointBindings services transitInterfaces;
  };
  relationRules = import ./upstream-selector-relations.nix {
    inherit common endpointContext trafficTypeMatches;
  };
  inherit (endpointContext) coreInterfaces policyInterfaces listOrEmpty;

  routeList =
    routes:
    (if builtins.isList (routes.ipv4 or null) then routes.ipv4 else [ ])
    ++ (if builtins.isList (routes.ipv6 or null) then routes.ipv6 else [ ]);

  uniqueSourcePrefixes =
    prefixes:
    builtins.attrValues (
      builtins.listToAttrs (
        map (entry: {
          name = "${builtins.toString (entry.family or "")}|${entry.prefix or ""}";
          value = entry;
        }) prefixes
      )
    );

  runtimeOriginSourcePrefixes =
    iface:
    let
      isHostPrefix =
        route:
        builtins.isAttrs route
        && builtins.isString (route.dst or null)
        && (route.policyOnly or false) != true
        && (((route.intent or { }).kind or null) == "internal-reachability")
        && (builtins.match ".*/32" route.dst != null || builtins.match ".*/128" route.dst != null);
    in
    uniqueSourcePrefixes (
      map (route: {
        family = if builtins.match ".*:.*" route.dst != null then 6 else 4;
        prefix = route.dst;
      }) (builtins.filter isHostPrefix (routeList (iface.routes or { })))
    );

  isOverlayCoreInterface =
    iface: builtins.any (uplink: builtins.elem uplink overlayNames) (common.uplinks iface);

  runtimeOriginCoreInterfaces = builtins.filter (
    iface: isOverlayCoreInterface iface && runtimeOriginSourcePrefixes iface != [ ]
  ) coreInterfaces;

  wanCoreInterfacesFor =
    sourceIface:
    let
      sourceUplinks = common.uplinks sourceIface;
    in
    let
      candidates = builtins.sort (a: b: a.runtimeIfName < b.runtimeIfName) (
        builtins.filter (
          iface:
          iface.runtimeIfName != sourceIface.runtimeIfName
          && !(builtins.any (uplink: builtins.elem uplink sourceUplinks) (common.uplinks iface))
        ) coreInterfaces
      );
    in
    if candidates == [ ] then [ ] else [ (builtins.head candidates) ];

  runtimeOriginRules = builtins.concatLists (
    map (
      sourceIface:
      map (
        wanIface:
        {
          action = "accept";
          intent = {
            kind = "runtime-origin-egress";
            source = "loopback-runtime-identity";
          };
          fromInterface = sourceIface.runtimeIfName;
          toInterface = wanIface.runtimeIfName;
          sourcePrefixes = runtimeOriginSourcePrefixes sourceIface;
          applyTcpMssClamp = false;
        }
        // common.selectorRuntimeRuleAudit {
          relationId = "runtime-origin-egress";
          direction = "core-runtime-origin-egress";
          fromIface = sourceIface;
          toIface = wanIface;
          decomposed = true;
          sourcePrefixes = runtimeOriginSourcePrefixes sourceIface;
        }
      ) (wanCoreInterfacesFor sourceIface)
    ) runtimeOriginCoreInterfaces
  );

  coreForPolicy =
    policyIface:
    let
      cores = coresForPolicy policyIface;
    in
    if cores == [ ] then null else builtins.head cores;

  # FS-370 / FS-481: a policy->upstream-selector lane binds one **source
  # scope** to one selected exit, so a scope with N permitted exits is
  # realized as N per-exit lanes (FS-370-SMS-050 requires a non-null
  # lane.uplink on every access-uplink lane). The upstream-selector -- not
  # the individual lane -- owns the multi-exit (ECMP) choice: it installs one
  # ECMP default across every core reachable via the scope's exit set
  # (policyLaneCombinedCoreDefaultPlan). A packet can therefore ingress on the
  # lane for exit `onyx` and egress the core for `opal`. The forwarding rule
  # must mirror that authority, so the admissible core set is derived from the
  # scope's **full exit set**, not from the single exit named by the ingress
  # lane. Pairing each lane only with its own exit core leaves cross-exit ECMP
  # traffic (e.g. clients-vpn ingressing `--uplink-onyx` but routed out the
  # `opal` core) with no forward accept, so it is dropped.
  scopeUplinks =
    builtins.foldl' (
      acc: iface:
      let
        scope = common.laneScope iface;
        exits = common.laneUplinks iface;
      in
      if scope == null then
        acc
      else
        acc
        // {
          ${toString scope} = builtins.attrNames (
            builtins.listToAttrs (
              map (u: {
                name = u;
                value = true;
              }) (builtins.filter (u: u != null) ((acc.${toString scope} or [ ]) ++ exits))
            )
          );
        }
    ) { } policyInterfaces;

  # Every core whose uplink(s) intersect the **scope's** exit set.
  coresForPolicy =
    policyIface:
    let
      scope = common.laneScope policyIface;
      policyUplinks =
        if scope != null && builtins.hasAttr (toString scope) scopeUplinks then
          scopeUplinks.${toString scope}
        else
          common.laneUplinks policyIface;
    in
    builtins.filter (
      coreIface:
      builtins.any (uplink: builtins.elem uplink (common.uplinks coreIface)) policyUplinks
    ) coreInterfaces;

  # For every policy interface, also generate forwarding rules to internet
  # egress core interfaces so that egress surface constraints match when
  # routing selects internet egress for tenant traffic.  Without this, traffic
  # whose intent allow rule names a specific uplink (e.g. testnet-host-isp)
  # cannot reach an internet egress core even though the CPM internetModes
  # on that core cover the tenant's source prefixes.
  # Internet egress cores are identified structurally: core interfaces that
  # serve non-overlay uplinks (not solely transport/overlay cores).
  internetEgressCoreInterfaces = builtins.filter (
    coreIface: !(isOverlayCoreInterface coreIface)
  ) coreInterfaces;

  additionalCoresForPolicy =
    policyIface:
    let
      primaryCore = coreForPolicy policyIface;
      primaryIsOverlay = primaryCore != null && isOverlayCoreInterface primaryCore;
    in
    if primaryIsOverlay then
      [ ]
    else
      builtins.filter (
        coreIface: primaryCore == null || coreIface.runtimeIfName != primaryCore.runtimeIfName
      ) internetEgressCoreInterfaces;

  # Generate pair rules for additional cores (internetModes-based coverage)
  additionalSelectorPairRules = builtins.concatLists (
    map (
      policyIface:
      let
        extraCores = additionalCoresForPolicy policyIface;
      in
      builtins.concatLists (
        map (
          coreIface:
          let
            policySourcePrefixes = common.sourcePrefixesAllowedToInterface (common.sourcePrefixesForInterface siteRuntimeOriginSourcePrefixes policyIface) coreIface;
          in
          common.selectorPairRule policyIface coreIface
          ++ (
            if policySourcePrefixes == [ ] then
              [ ]
            else
              [
                (common.withSourcePrefixes (
                  {
                    action = "accept";
                    intent = {
                      kind = "runtime-origin-egress";
                      source = "loopback-runtime-identity";
                      stage = "upstream-selector-policy-core-egress";
                    };
                    fromInterface = policyIface.runtimeIfName;
                    toInterface = coreIface.runtimeIfName;
                    applyTcpMssClamp = true;
                  }
                  // common.selectorRuntimeRuleAudit {
                    relationId = "runtime-origin-egress";
                    direction = "forward-runtime-origin";
                    fromIface = policyIface;
                    toIface = coreIface;
                    decomposed = true;
                    sourcePrefixes = policySourcePrefixes;
                  }
                ) policySourcePrefixes)
              ]
          )
          ++ [
            (common.withSourcePrefixes (
              {
                action = "accept";
                fromInterface = coreIface.runtimeIfName;
                toInterface = policyIface.runtimeIfName;
                applyTcpMssClamp = false;
                connectionState = "established,related";
                returnRule = true;
              }
              // common.selectorRuntimeRuleAudit {
                relationId = "runtime-origin-egress";
                direction = "reverse-runtime-origin";
                fromIface = coreIface;
                toIface = policyIface;
                decomposed = true;
                statefulReturn = true;
              }
            ) (common.sourcePrefixesReachableVia siteRuntimeOriginSourcePrefixes coreIface))
          ]
        ) extraCores
      )
    ) policyInterfaces
  );

  selectorPairRules = builtins.concatLists (
    map (
      policyIface:
      let
        matchingCores = coresForPolicy policyIface;
      in
      builtins.concatLists (
        map (
          coreIface:
          let
            policySourcePrefixes = common.sourcePrefixesAllowedToInterface (common.sourcePrefixesForInterface siteRuntimeOriginSourcePrefixes policyIface) coreIface;
          in
          common.selectorPairRule policyIface coreIface
          ++ (
            if policySourcePrefixes == [ ] then
              [ ]
            else
              [
                (common.withSourcePrefixes (
                  {
                    action = "accept";
                    intent = {
                      kind = "runtime-origin-egress";
                      source = "loopback-runtime-identity";
                      stage = "upstream-selector-policy-core-egress";
                    };
                    fromInterface = policyIface.runtimeIfName;
                    toInterface = coreIface.runtimeIfName;
                    applyTcpMssClamp = true;
                  }
                  // common.selectorRuntimeRuleAudit {
                    relationId = "runtime-origin-egress";
                    direction = "forward-runtime-origin";
                    fromIface = policyIface;
                    toIface = coreIface;
                    decomposed = true;
                    sourcePrefixes = policySourcePrefixes;
                  }
                ) policySourcePrefixes)
              ]
          )
          ++ [
            (common.withSourcePrefixes (
              {
                action = "accept";
                fromInterface = coreIface.runtimeIfName;
                toInterface = policyIface.runtimeIfName;
                applyTcpMssClamp = false;
                connectionState = "established,related";
                returnRule = true;
              }
              // common.selectorRuntimeRuleAudit {
                relationId = "runtime-origin-egress";
                direction = "reverse-runtime-origin";
                fromIface = coreIface;
                toIface = policyIface;
                decomposed = true;
                statefulReturn = true;
              }
            ) (common.sourcePrefixesReachableVia siteRuntimeOriginSourcePrefixes coreIface))
          ]
        ) matchingCores
      )
    ) policyInterfaces
  );
  genericEgressRules =
    if egressEnabled then
      selectorPairRules
      ++ additionalSelectorPairRules
      ++ relationRules.runtimeRoutedPrefixPublicEgressRules
      ++ runtimeOriginRules
      ++ common.runtimeOriginDefaultForwardRules siteRuntimeOriginSourcePrefixes policyInterfaces
    else
      [ ];
in
genericEgressRules
++ builtins.concatLists (map relationRules.externalTransitRule (listOrEmpty relations))
++ builtins.concatLists (map relationRules.overlayUnderlayTransitRule (listOrEmpty relations))
++ builtins.concatLists (map relationRules.externalServiceTransitRule (listOrEmpty relations))
