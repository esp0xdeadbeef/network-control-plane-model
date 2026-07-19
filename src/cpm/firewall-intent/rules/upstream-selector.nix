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
      matchesCore = builtins.filter (
        coreIface: builtins.elem (common.laneUplink policyIface) (common.uplinks coreIface)
      ) coreInterfaces;
    in
    if matchesCore == [ ] then null else builtins.elemAt matchesCore 0;

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
    in
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
        coreIface = coreForPolicy policyIface;
      in
      if coreIface == null then
        [ ]
      else
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
