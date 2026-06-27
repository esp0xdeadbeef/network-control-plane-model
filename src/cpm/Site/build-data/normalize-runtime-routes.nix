{ lib
, common
, overlayNames ? [ ]
, attachments ? [ ]
, routedPrefixesByTenant ? { }
,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

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
    slot:
    let
      tableId = 1000 + slot;
      dynamicRulePriority = 10000 + slot;
    in
    {
      source = "control-plane-model";
      allocation = "runtime-ifname-sorted-slot";
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

  indexedInterfaceAllocations =
    interfaces:
    let
      ifNames = builtins.attrNames interfaces;
      sortedIfNames =
        builtins.sort
          (left: right: (interfaceRuntimeName interfaces left) < (interfaceRuntimeName interfaces right))
          ifNames;
      count = builtins.length sortedIfNames;
      entries =
        builtins.genList
          (index:
            let
              ifName = builtins.elemAt sortedIfNames index;
            in
            {
              name = ifName;
              value = policyRoutingAllocationFor (index + 1);
            })
          count;
    in
      builtins.listToAttrs entries;

  addPolicyRoutingAllocations =
    interfaces:
    let
      allocations = indexedInterfaceAllocations interfaces;
    in
      builtins.mapAttrs
        (ifName: iface:
          iface // { policyRoutingAllocation = allocations.${ifName}; })
        interfaces;

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
              _ifName: iface:
                let
                  routes = attrsOrEmpty (iface.routes or null);
                  dropWrongRuntimeOriginRoute = isRuntimeOriginSourceRouteOnPolicyUplink targetRole runtimeOriginPrefixes iface;
                  ipv4 = uniqueKernelDefaults 4 (
                    dropDuplicateUnlanedDefaults 4 (
                      builtins.filter (route: route != null) (
                        builtins.map (classifyTargetRoute 4) (
                          builtins.filter (route: !dropWrongRuntimeOriginRoute route) (listOrEmpty (routes.ipv4 or null))
                        )
                      )
                    )
                  );
                  ipv6 = uniqueKernelDefaults 6 (
                    dropDuplicateUnlanedDefaults 6 (
                      builtins.filter (route: route != null) (
                        builtins.map (classifyTargetRoute 6) (
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
              base4 = ipv4 ++ runtimeOriginReturnRoutes 4 target iface ipv4;
              base6 = ipv6 ++ runtimeOriginReturnRoutes 6 target iface ipv6;
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
          interfaces = addPolicyRoutingAllocations (appendPostInitialComplements target interfaces);
        };
      }
    else
      target
      // {
        effectiveRuntimeRealization = effective // {
          interfaces = addPolicyRoutingAllocations normalizedInterfaces;
        };
      };

  normalizeRuntimeTargetRoutes =
    normalizeRuntimeTargetRoutesWith { };

  normalizeRuntimeTargetRoutesAfterPolicyComplements =
    normalizeRuntimeTargetRoutesWith { postInitialComplementsOnly = true; };
in
{
  inherit normalizeRuntimeTargetRoutes normalizeRuntimeTargetRoutesAfterPolicyComplements normalizeRuntimeTargetRoutesWith uniqueRoutes;
}
