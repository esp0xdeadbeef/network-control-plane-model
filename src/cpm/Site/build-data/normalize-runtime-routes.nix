{ lib
, common
, overlayNames ? [ ]
, attachments ? [ ]
, routedPrefixesByTenant ? { }
, tenantPrefixOwners ? { }
, trafficPaths ? [ ]
,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  # Uplink groups that share one modeled egress relation (the traffic path's
  # destination.uplinks with more than one member). Those are the ECMP lanes:
  # the upstream-selector must place their default routes in the same policy
  # table so the renderer can collapse them into a MultiPathRoute.
  multipathUplinkGroups =
    lib.unique (
      builtins.filter (group: builtins.length group > 1) (
        builtins.map
          (path:
            lib.sort builtins.lessThan (
              listOrEmpty ((attrsOrEmpty (path.destination or null)).uplinks or null)
            ))
          trafficPaths
      )
    );

  multipathGroupSlot =
    builtins.listToAttrs (
      builtins.genList
        (idx: {
          name = builtins.concatStringsSep "," (builtins.elemAt multipathUplinkGroups idx);
          value = idx + 1;
        })
        (builtins.length multipathUplinkGroups)
    );

  defaultDst = family: if family == 4 then "0.0.0.0/0" else "::/0";
  routeIdentity = import ./runtime-route-identity.nix { inherit attrsOrEmpty defaultDst; };
  inherit (routeIdentity) routeKey uniqueRoutes isPolicyDefault;
  routePolicy = import ./runtime-route-policy.nix {
    inherit
      lib
      attrsOrEmpty
      listOrEmpty
      defaultDst
      ;
  };
  inherit (routePolicy)
    rolesWithPolicyDefaults
    runtimePrefixExitNodes
    classifyRoute
    policyDefaultRoutes
    policyTableComplements
    ;
  inherit (import ./route-kernel-defaults.nix { inherit defaultDst; }) uniqueKernelDefaults;
  inherit (import ./route-defaults.nix { inherit attrsOrEmpty defaultDst; })
    dropDuplicateUnlanedDefaults
    ;
  runtimeOriginRoutes = import ./runtime-origin-route-helpers.nix {
    inherit
      lib
      attrsOrEmpty
      listOrEmpty
      defaultDst
      ;
  };
  inherit (runtimeOriginRoutes)
    laneKind
    runtimeOriginPrefixesFromTarget
    isRuntimeOriginSourceRouteOnPolicyUplink
    isRuntimeOriginSourcePolicyComplementOnPolicyUplink
    runtimeOriginReturnRoutes
    canGeneratePolicyTableComplement
    ;
  runtimeExitNodes = runtimePrefixExitNodes { inherit attachments routedPrefixesByTenant; };

  isPostInitialRoute =
    route:
    let
      kind = (attrsOrEmpty (route.intent or null)).kind or null;
    in
    builtins.elem kind [
      "dns-forwarder-reachability"
      "service-dns-reachability"
      "service-endpoint-reachability"
    ];

  complementSourceRoutes =
    postInitialOnly: routes:
    builtins.filter
      (route:
      canGeneratePolicyTableComplement route
      && (!postInitialOnly || isPostInitialRoute route))
      routes;

  reverseList =
    values:
    builtins.foldl' (acc: value: [ value ] ++ acc) [ ] values;

  interfaceLane =
    iface: attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);

  interfaceUplinks =
    iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = interfaceLane iface;
    in
    lib.unique (
      listOrEmpty (backingRef.uplinks or null)
      ++ listOrEmpty (lane.uplinks or null)
      ++ (if builtins.isString (lane.uplink or null) && lane.uplink != "" then [ lane.uplink ] else [ ])
    );

  ownerForPrefix =
    family: dst:
    let
      record = attrsOrEmpty (tenantPrefixOwners."${builtins.toString family}|${dst}" or null);
    in
      record.owner or null;

  isUpstreamSelectorCoreDefaultInterface =
    targetRole: iface:
    targetRole == "upstream-selector"
    && interfaceUplinks iface != [ ]
    && ((interfaceLane iface).access or null) == null;

  isUpstreamSelectorAccessUplinkInterface =
    targetRole: iface:
    let lane = interfaceLane iface;
    in
    targetRole == "upstream-selector"
    && (lane.kind or null) == "access-uplink"
    && (lane.access or null) != null
    && builtins.isString (lane.uplink or null)
    && lane.uplink != "";

  upstreamSelectorPolicyDefaultComplements =
    family: targetRole: policyIface: interfaces:
    if !(isUpstreamSelectorAccessUplinkInterface targetRole policyIface) then
      [ ]
    else
      let
        policyLane = interfaceLane policyIface;
        policyUplink = policyLane.uplink or null;
        routesFor = iface: listOrEmpty ((attrsOrEmpty (iface.routes or null))."ipv${builtins.toString family}" or null);
        coreIfaces = builtins.filter
          (
            iface:
            isUpstreamSelectorCoreDefaultInterface targetRole iface
            && builtins.elem policyUplink (interfaceUplinks iface)
          )
          (builtins.attrValues interfaces);
        defaultRouteFor =
          route:
          if
            !builtins.isAttrs route
            || (route.dst or null) != defaultDst family
            || ((route.via4 or null) == null && (route.via6 or null) == null)
          then
            null
          else
            route
            // {
              lane = policyLane;
              policyOnly = true;
              reason = "policy-table-default-reachability";
              intent = (attrsOrEmpty (route.intent or null)) // {
                policyTableDefaultComplement = true;
                source = "policy-default-lane";
              };
            };
      in
      builtins.filter (route: route != null) (
        builtins.concatLists (
          builtins.map (coreIface: builtins.map defaultRouteFor (routesFor coreIface)) coreIfaces
        )
      );

  upstreamSelectorCorePolicyComplements =
    family: targetRole: coreIface: interfaces:
    if !(isUpstreamSelectorCoreDefaultInterface targetRole coreIface) then
      [ ]
    else
      let
        coreUplinks = interfaceUplinks coreIface;
        routesFor = iface: listOrEmpty ((attrsOrEmpty (iface.routes or null))."ipv${builtins.toString family}" or null);
        coreHasDefault =
          builtins.any
            (route: builtins.isAttrs route && (route.dst or null) == defaultDst family)
            (routesFor coreIface);
        policyIfaces = builtins.filter
          (
            iface:
            let
              lane = interfaceLane iface;
              uplink = lane.uplink or null;
            in
            (lane.kind or null) == "access-uplink"
            && (lane.access or null) != null
            && builtins.isString uplink
            && builtins.elem uplink coreUplinks
          )
          (builtins.attrValues interfaces);
        complementRouteFor =
          iface: route:
          let
            lane = interfaceLane iface;
            access = lane.access or null;
          in
          if
            !builtins.isAttrs route
            || (route.policyOnly or false) == true
            || (route.dst or null) == null
            || (route.dst or null) == defaultDst family
            || ownerForPrefix family route.dst != access
          then
            null
          else
            route
            // {
              lane = lane;
              policyOnly = true;
              reason = "policy-table-internal-reachability";
              intent = (attrsOrEmpty (route.intent or null)) // {
                policyTableComplement = true;
                source = "policy-default-lane";
              };
            };
      in
      if !coreHasDefault then
        [ ]
      else
        builtins.filter (route: route != null) (
          builtins.concatLists (
            builtins.map (iface: builtins.map (complementRouteFor iface) (routesFor iface)) policyIfaces
          )
        );

  routeKeySet =
    family: routes:
    builtins.foldl'
      (seen: route:
      let key = routeKey family route;
      in
      if key == null then seen else seen // { ${key} = true; })
      { }
      routes;

  appendUniqueRoutes =
    family: baseRoutes: extraRoutes:
    if extraRoutes == [ ] then
      baseRoutes
    else
      let
        result =
          builtins.foldl'
            (acc: route:
              let key = routeKey family route;
              in
              if key == null || builtins.hasAttr key acc.seen then
                acc
              else
                {
                  seen = acc.seen // { ${key} = true; };
                  values = [ route ] ++ acc.values;
                })
            {
              seen = routeKeySet family baseRoutes;
              values = [ ];
            }
            extraRoutes;
      in
      baseRoutes ++ reverseList result.values;

  appendPostInitialComplements =
    target: interfaces:
    let
      targetRole = target.role or "";
      runtimeOriginPrefixes = runtimeOriginPrefixesFromTarget target;
      policyDefaults4 =
        if builtins.hasAttr targetRole rolesWithPolicyDefaults then
          policyDefaultRoutes { inherit isPolicyDefault; } 4 interfaces
        else
          [ ];
      policyDefaults6 =
        if builtins.hasAttr targetRole rolesWithPolicyDefaults then
          policyDefaultRoutes { inherit isPolicyDefault; } 6 interfaces
        else
          [ ];
    in
    builtins.mapAttrs
      (
        _ifName: iface:
        let
          routes = attrsOrEmpty (iface.routes or null);
          ipv4 = listOrEmpty (routes.ipv4 or null);
          ipv6 = listOrEmpty (routes.ipv6 or null);
          dropWrongRuntimeOriginComplement =
            isRuntimeOriginSourcePolicyComplementOnPolicyUplink targetRole runtimeOriginPrefixes iface;
          return4 = runtimeOriginReturnRoutes 4 target iface ipv4;
          return6 = runtimeOriginReturnRoutes 6 target iface ipv6;
          baseRaw4 =
            builtins.filter
              (route: !dropWrongRuntimeOriginComplement route)
              (ipv4 ++ return4);
          baseRaw6 =
            builtins.filter
              (route: !dropWrongRuntimeOriginComplement route)
              (ipv6 ++ return6);
          base4 = if return4 == [ ] then baseRaw4 else uniqueRoutes 4 baseRaw4;
          base6 = if return6 == [ ] then baseRaw6 else uniqueRoutes 6 baseRaw6;
          postInitial4 =
            builtins.filter
              (route: !dropWrongRuntimeOriginComplement route)
              (complementSourceRoutes true base4);
          postInitial6 =
            builtins.filter
              (route: !dropWrongRuntimeOriginComplement route)
              (complementSourceRoutes true base6);
          ifaceLane = (attrsOrEmpty (iface.backingRef or null)).lane or null;
          taggedPostInitial4 =
            if ifaceLane != null then
              builtins.map (route: route // { lane = ifaceLane; }) postInitial4
            else
              postInitial4;
          taggedPostInitial6 =
            if ifaceLane != null then
              builtins.map (route: route // { lane = ifaceLane; }) postInitial6
            else
              postInitial6;
          extra4 =
            builtins.filter
              (route: !dropWrongRuntimeOriginComplement route)
              (policyTableComplements 4 policyDefaults4 taggedPostInitial4);
          extra6 =
            builtins.filter
              (route: !dropWrongRuntimeOriginComplement route)
              (policyTableComplements 6 policyDefaults6 taggedPostInitial6);
          final4 = appendUniqueRoutes 4 base4 extra4;
          final6 = appendUniqueRoutes 6 base6 extra6;
        in
        if return4 == [ ] && return6 == [ ] && extra4 == [ ] && extra6 == [ ] then
          iface
        else
          iface
          // {
            routes = routes // {
              ipv4 = final4;
              ipv6 = final6;
            };
          }
      )
      interfaces;

  policyRoutingAllocationFor =
    allocation: slot:
    let
      tableId = 1000 + slot;
      dynamicRulePriority = 10000 + slot;
    in
    {
      source = "control-plane-model";
      inherit allocation;
      inherit tableId dynamicRulePriority;
      priority = dynamicRulePriority;
      tableRulePriority = tableId;
      mainSuppressPriority = 11000 + slot;
    };

  interfaceRuntimeName =
    interfaces: ifName:
    let
      iface = attrsOrEmpty interfaces.${ifName};
      runtimeIfName = iface.runtimeIfName or null;
    in
    if builtins.isString runtimeIfName && runtimeIfName != "" then runtimeIfName else ifName;

  interfacePolicyRoutingRank =
    target: iface:
    let
      targetRole = target.role or "";
      sourceKind = iface.sourceKind or null;
      lane = attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);
      laneKind = lane.kind or null;
    in
    if targetRole == "access" && sourceKind == "tenant" then
      10
    else if targetRole == "access" && sourceKind == "p2p" && laneKind == "access-edge" then
      20
    else
      100;

  allocationMethodFor =
    target: interfaces:
    let
      ranks = builtins.map (ifName: interfacePolicyRoutingRank target interfaces.${ifName}) (builtins.attrNames interfaces);
    in
    if builtins.any (rank: rank != 100) ranks then
      "semantic-interface-class-slot"
    else
      "runtime-ifname-sorted-slot";

  indexedInterfaceAllocations =
    target: interfaces:
    let
      allocationMethod = allocationMethodFor target interfaces;
      targetRole = target.role or "";
      ifNames = builtins.attrNames interfaces;
      sortedIfNames =
        builtins.sort
          (
            left: right:
            let
              leftRank = interfacePolicyRoutingRank target interfaces.${left};
              rightRank = interfacePolicyRoutingRank target interfaces.${right};
            in
            if leftRank == rightRank then
              (interfaceRuntimeName interfaces left) < (interfaceRuntimeName interfaces right)
            else
              leftRank < rightRank
          )
          ifNames;
      count = builtins.length sortedIfNames;
      # The core's fabric p2p and WAN uplink must share one policy table so the
      # tenant traffic forwarded in from the fabric can reach the WAN default
      # route (which is DHCP-provided and therefore only present in the WAN's
      # table). Giving them distinct slots strands the fabric ingress in a table
      # with return routes but no default.
      coreSharedSlot =
        if targetRole == "core" then count else null;
      slotFor =
        index: ifName:
        if coreSharedSlot != null then
          coreSharedSlot
        else if targetRole == "upstream-selector" then
          let
            iface = attrsOrEmpty interfaces.${ifName};
            lane = attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);
            laneKind = lane.kind or null;
            uplinkName = lane.uplink or null;
            group =
              if laneKind == "uplink" && builtins.isString uplinkName && uplinkName != "" then
                lib.findFirst (g: builtins.elem uplinkName g) null multipathUplinkGroups
              else
                null;
            groupKey =
              if group == null then null else builtins.concatStringsSep "," group;
          in
          if groupKey != null && builtins.hasAttr groupKey multipathGroupSlot then
            multipathGroupSlot.${groupKey}
          else
            (builtins.length multipathUplinkGroups) + index + 1
        else
          index + 1;
      entries =
        builtins.genList
          (index:
            let
              ifName = builtins.elemAt sortedIfNames index;
            in
            {
              name = ifName;
              value = policyRoutingAllocationFor allocationMethod (slotFor index ifName);
            })
          count;
    in
    builtins.listToAttrs entries;

  addPolicyRoutingAllocations =
    target: interfaces:
    let
      allocations = indexedInterfaceAllocations target interfaces;
    in
    builtins.mapAttrs
      (ifName: iface:
      iface // { policyRoutingAllocation = allocations.${ifName}; })
      interfaces;

  addPolicyRoutingAllocationsToTarget =
    target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
    in
    if interfaces == { } then
      target
    else
      target
      // {
        effectiveRuntimeRealization = effective // {
          interfaces = addPolicyRoutingAllocations target interfaces;
        };
      };

  interfaceRouteSource =
    ifName: iface:
    if (iface.upstream or null) != null then
      toString iface.upstream
    else if (iface.uplink or null) != null then
      toString iface.uplink
    else if (iface.name or null) != null then
      toString iface.name
    else if (iface.interface or null) != null then
      toString iface.interface
    else
      toString ifName;

  normalizeRuntimeLearnedIntent =
    family: ifName: iface: route:
    if !builtins.isAttrs route then
      route
    else
      let
        intent = attrsOrEmpty (route.intent or null);
        sourcePeerOrProvider = interfaceRouteSource ifName iface;
      in
      if (intent.kind or null) != "uplink-learned-reachability" then
        route
      else
        route
        // {
          intent = intent // {
            kind = "uplink-learned-reachability";
            source = intent.source or "explicit-uplink";
            routeSource = intent.routeSource or (intent.source or "explicit-uplink");
            sourcePeerOrProvider = intent.sourcePeerOrProvider or sourcePeerOrProvider;
            routePurpose =
              intent.routePurpose or (
                if (route.dst or null) == defaultDst family then "wan-internet" else "provider-prefix"
              );
            maximumScope = intent.maximumScope or "provider";
            rejectionBehavior = intent.rejectionBehavior or "reject";
            routeAvailabilityOnly =
              if intent ? routeAvailabilityOnly then intent.routeAvailabilityOnly else true;
            policyAuthority =
              if intent ? policyAuthority then intent.policyAuthority else false;
          };
        };

  normalizeRuntimeTargetRoutesWith =
    { postInitialComplementsOnly ? false, globalAddr4Access ? { } }:
    target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      targetRole = target.role or "";
      runtimeOriginPrefixes = runtimeOriginPrefixesFromTarget target;
      classifyTargetRoute = classifyRoute { inherit overlayNames runtimeExitNodes targetRole; };
      classifiedInterfaces =
        if postInitialComplementsOnly then
          interfaces
        else
          builtins.mapAttrs
            (
              ifName: iface:
                let
                  routes = attrsOrEmpty (iface.routes or null);
                  dropWrongRuntimeOriginRoute = isRuntimeOriginSourceRouteOnPolicyUplink targetRole runtimeOriginPrefixes iface;
                  ipv4 = uniqueKernelDefaults 4 (
                    dropDuplicateUnlanedDefaults 4 (
                      builtins.filter (route: route != null) (
                        builtins.map (route: normalizeRuntimeLearnedIntent 4 ifName iface (classifyTargetRoute 4 route)) (
                          builtins.filter (route: !dropWrongRuntimeOriginRoute route) (listOrEmpty (routes.ipv4 or null))
                        )
                      )
                    )
                  );
                  ipv6 = uniqueKernelDefaults 6 (
                    dropDuplicateUnlanedDefaults 6 (
                      builtins.filter (route: route != null) (
                        builtins.map (route: normalizeRuntimeLearnedIntent 6 ifName iface (classifyTargetRoute 6 route)) (
                          builtins.filter (route: !dropWrongRuntimeOriginRoute route) (listOrEmpty (routes.ipv6 or null))
                        )
                      )
                    )
                  );
                in
                if ipv4 == [ ] && ipv6 == [ ] then
                  iface
                else
                  iface
                  // {
                    routes = routes // {
                      ipv4 = uniqueRoutes 4 ipv4;
                      ipv6 = uniqueRoutes 6 ipv6;
                    };
                  }
            )
            interfaces;
      policyDefaults4 =
        if builtins.hasAttr targetRole rolesWithPolicyDefaults then
          policyDefaultRoutes { inherit isPolicyDefault; } 4 classifiedInterfaces
        else
          [ ];
      policyDefaults6 =
        if builtins.hasAttr targetRole rolesWithPolicyDefaults then
          policyDefaultRoutes { inherit isPolicyDefault; } 6 classifiedInterfaces
        else
          [ ];
      normalizedInterfaces = builtins.mapAttrs
        (
          _ifName: iface:
            let
              routes = attrsOrEmpty (iface.routes or null);
              ipv4 = listOrEmpty (routes.ipv4 or null);
              ipv6 = listOrEmpty (routes.ipv6 or null);
              base4 =
                ipv4
                ++ runtimeOriginReturnRoutes 4 target iface ipv4
                ++ upstreamSelectorPolicyDefaultComplements 4 targetRole iface classifiedInterfaces
                ++ upstreamSelectorCorePolicyComplements 4 targetRole iface classifiedInterfaces;
              base6 =
                ipv6
                ++ runtimeOriginReturnRoutes 6 target iface ipv6
                ++ upstreamSelectorPolicyDefaultComplements 6 targetRole iface classifiedInterfaces
                ++ upstreamSelectorCorePolicyComplements 6 targetRole iface classifiedInterfaces;
              dropWrongRuntimeOriginComplement =
                isRuntimeOriginSourcePolicyComplementOnPolicyUplink targetRole runtimeOriginPrefixes iface;
              complementBase4 = complementSourceRoutes postInitialComplementsOnly base4;
              complementBase6 = complementSourceRoutes postInitialComplementsOnly base6;
              ifaceLane = (attrsOrEmpty (iface.backingRef or null)).lane or null;
              ifaceAccess = (attrsOrEmpty ifaceLane).access or null;
              # Filter: remove source routes whose dst belongs to a different access.
              # Uses global addr4->access map to determine which access owns each dst.
              ownLaneComplementBase4 = builtins.filter
                (route:
                  let
                    dst = route.dst or "";
                    dstAccess = globalAddr4Access.${dst} or null;
                  in
                  dstAccess == null || dstAccess == ifaceAccess)
                complementBase4;
              ownLaneComplementBase6 = complementBase6;
              taggedComplementBase4 =
                if ifaceLane != null then
                  builtins.map (route: route // { lane = ifaceLane; }) ownLaneComplementBase4
                else
                  ownLaneComplementBase4;
              taggedComplementBase6 =
                if ifaceLane != null then
                  builtins.map (route: route // { lane = ifaceLane; }) complementBase6
                else
                  complementBase6;
              augmented4 = builtins.filter (route: !dropWrongRuntimeOriginComplement route) (
                base4 ++ policyTableComplements 4 policyDefaults4 taggedComplementBase4
              );
              augmented6 = builtins.filter (route: !dropWrongRuntimeOriginComplement route) (
                base6 ++ policyTableComplements 6 policyDefaults6 taggedComplementBase6
              );
            in
            iface
            // {
              routes = routes // {
                ipv4 = uniqueRoutes 4 augmented4;
                ipv6 = uniqueRoutes 6 augmented6;
              };
            }
        )
        classifiedInterfaces;
    in
    if interfaces == { } then
      target
    else if postInitialComplementsOnly then
      target
      // {
        effectiveRuntimeRealization = effective // {
          interfaces = addPolicyRoutingAllocations target (appendPostInitialComplements target interfaces);
        };
      }
    else
      target
      // {
        effectiveRuntimeRealization = effective // {
          interfaces = addPolicyRoutingAllocations target normalizedInterfaces;
        };
      };

  normalizeRuntimeTargetRoutes =
    normalizeRuntimeTargetRoutesWith { };

  normalizeRuntimeTargetRoutesAfterPolicyComplements =
    normalizeRuntimeTargetRoutesWith { postInitialComplementsOnly = true; };
in
{
  inherit addPolicyRoutingAllocationsToTarget normalizeRuntimeTargetRoutes normalizeRuntimeTargetRoutesAfterPolicyComplements normalizeRuntimeTargetRoutesWith uniqueRoutes;
}
