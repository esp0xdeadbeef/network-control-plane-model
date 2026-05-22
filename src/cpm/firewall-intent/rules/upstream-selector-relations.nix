{ common, endpointContext }:

let
  inherit (endpointContext)
    attrsOrEmpty
    listOrEmpty
    uniqueStrings
    coreInterfaces
    policyInterfaces
    serviceAccessNodes
    ;

  familyRoutes = routes: listOrEmpty (routes.ipv4 or null) ++ listOrEmpty (routes.ipv6 or null);

  routeIntent = route: attrsOrEmpty (route.intent or null);

  externalUplinks =
    endpoint:
    let
      value = attrsOrEmpty endpoint;
    in
    if (value.kind or null) != "external" then
      [ ]
    else
      (listOrEmpty (value.uplinks or null)) ++ (if value ? name then [ value.name ] else [ ]);

  coreInterfacesFor =
    endpoint:
    let
      wanted = externalUplinks endpoint;
    in
    builtins.filter (
      iface: builtins.any (uplink: builtins.elem uplink (common.uplinks iface)) wanted
    ) coreInterfaces;

  externalIngressInterfacesFor =
    endpoint:
    let
      wanted = externalUplinks endpoint;
      matches = builtins.filter (
        iface: builtins.any (uplink: builtins.elem uplink (common.uplinks iface)) wanted
      ) (coreInterfaces ++ policyInterfaces);
    in
    builtins.attrValues (
      builtins.listToAttrs (
        map (iface: {
          name = iface.runtimeIfName;
          value = iface;
        }) matches
      )
    );

  servicePolicyInterfacesFor =
    endpoint:
    let
      accessNodes = serviceAccessNodes endpoint;
    in
    builtins.filter (iface: builtins.elem (common.laneAccess iface) accessNodes) policyInterfaces;

  servicePolicyInterfacesForExternal =
    fromEndpoint: toEndpoint:
    let
      wantedUplinks = externalUplinks fromEndpoint;
      candidates = servicePolicyInterfacesFor toEndpoint;
    in
    builtins.filter (
      iface: builtins.any (uplink: builtins.elem uplink (common.uplinks iface)) wantedUplinks
    ) candidates;

  hasOverlayUnderlayEndpointRoute =
    overlayName: iface:
    builtins.any (
      route:
      builtins.isAttrs route
      && (route.overlay or null) == overlayName
      && (route.proto or null) == "underlay"
      && ((routeIntent route).kind or null) == "overlay-underlay-reachability"
    ) (familyRoutes (attrsOrEmpty (iface.routes or null)));

  pairRules =
    relation: fromIfaces: toIfaces: extra:
    let
      trafficType = relation.trafficType or "any";
    in
    builtins.concatLists (
      map (
        fromIface:
        map (
          toIface:
          {
            action = "accept";
            relationId = relation.id or null;
            priority = relation.priority or null;
            inherit trafficType;
            from = attrsOrEmpty (relation.from or null);
            to = attrsOrEmpty (relation.to or null);
            fromInterface = fromIface.runtimeIfName;
            toInterface = toIface.runtimeIfName;
            applyTcpMssClamp = false;
          }
          // extra
        ) toIfaces
      ) fromIfaces
    );

in
{
  externalTransitRule =
    relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromExternal = attrsOrEmpty (relation.from or null);
      toExternal = attrsOrEmpty (relation.to or null);
      fromIsNamedOverlay =
        (fromExternal.kind or null) == "external" && fromExternal ? name && !(fromExternal ? uplinks);
      toIsWanUplink =
        (toExternal.kind or null) == "external" && builtins.isList (toExternal.uplinks or null);
    in
    if
      (relation.action or "allow") != "allow"
      || (relation.trafficType or "any") == "any"
      || (fromIsNamedOverlay && toIsWanUplink)
    then
      [ ]
    else
      pairRules relation (coreInterfacesFor (relation.from or null)) (coreInterfacesFor (
        relation.to or null
      )) { };

  overlayUnderlayTransitRule =
    relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromExternal = attrsOrEmpty (relation.from or null);
      toExternal = attrsOrEmpty (relation.to or null);
      overlayName = fromExternal.name or null;
      fromIsNamedOverlay =
        (fromExternal.kind or null) == "external" && fromExternal ? name && !(fromExternal ? uplinks);
      toIsWanUplink =
        (toExternal.kind or null) == "external" && builtins.isList (toExternal.uplinks or null);
      toCores = builtins.filter (
        iface: overlayName != null && hasOverlayUnderlayEndpointRoute overlayName iface
      ) (coreInterfacesFor toExternal);
    in
    if
      (relation.action or "allow") != "allow"
      || (relation.trafficType or "any") == "any"
      || !fromIsNamedOverlay
      || !toIsWanUplink
    then
      [ ]
    else
      pairRules relation (coreInterfacesFor fromExternal) toCores {
        intent = {
          kind = "overlay-underlay-reachability";
          source = "overlay-underlay-endpoint";
          overlay = overlayName;
        };
      };

  externalServiceTransitRule =
    relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromEndpoint = attrsOrEmpty (relation.from or null);
      toEndpoint = attrsOrEmpty (relation.to or null);
    in
    if
      (relation.action or "allow") != "allow"
      || (fromEndpoint.kind or null) != "external"
      || (toEndpoint.kind or null) != "service"
    then
      [ ]
    else
      pairRules relation (externalIngressInterfacesFor fromEndpoint)
        (servicePolicyInterfacesForExternal fromEndpoint toEndpoint)
        { };

  runtimeRoutedPrefixPublicEgressRules =
    let
      isStaticIpv4RoutedSource =
        route:
        let
          intent = routeIntent route;
        in
        builtins.isAttrs route
        && builtins.isString (route.dst or null)
        && !(builtins.match ".*:.*" route.dst != null)
        && (route.family or 4) == 4
        && (intent.kind or null) == "overlay-reachability";

      runtimeRoutedPrefixStaticSources =
        iface:
        map
          (prefix: {
            family = 4;
            inherit prefix;
          })
          (
            builtins.attrNames (
              builtins.listToAttrs (
                map (route: {
                  name = route.dst;
                  value = true;
                }) (builtins.filter isStaticIpv4RoutedSource (familyRoutes (attrsOrEmpty (iface.routes or null))))
              )
            )
          );

      runtimeRoutedPrefixSourceFiles =
        iface:
        builtins.filter (sourceFile: builtins.isString sourceFile && sourceFile != "") (
          map (route: route.sourceFile or null) (
            builtins.filter (
              route:
              builtins.isAttrs route && ((routeIntent route).kind or null) == "runtime-routed-prefix-return"
            ) (familyRoutes (attrsOrEmpty (iface.routes or null)))
          )
        );
      fromCoresWithSourceScopes =
        builtins.filter (entry: entry.sourceFiles != [ ] || entry.sourcePrefixes != [ ])
          (
            map (iface: {
              inherit iface;
              sourceFiles = runtimeRoutedPrefixSourceFiles iface;
              sourcePrefixes = runtimeRoutedPrefixStaticSources iface;
            }) coreInterfaces
          );
      policyInterfacesForCore =
        coreIface:
        let
          matches = builtins.sort (a: b: (a.runtimeIfName or "") < (b.runtimeIfName or "")) (
            builtins.filter (
              policyIface:
              builtins.any (uplink: builtins.elem uplink (common.uplinks coreIface)) (common.uplinks policyIface)
            ) policyInterfaces
          );
        in
        if matches == [ ] then [ ] else [ (builtins.head matches) ];
      exitPolicyInterfacesFor =
        ingressPolicyIface:
        builtins.filter (
          iface:
          iface.runtimeIfName != ingressPolicyIface.runtimeIfName
          && (common.laneAccess iface) == (common.laneAccess ingressPolicyIface)
          && !builtins.any (uplink: builtins.elem uplink (common.uplinks ingressPolicyIface)) (
            common.uplinks iface
          )
        ) policyInterfaces;
      exitCoreInterfacesFor =
        exitPolicyIface:
        builtins.filter (
          coreIface:
          builtins.any (uplink: builtins.elem uplink (common.uplinks exitPolicyIface)) (
            common.uplinks coreIface
          )
        ) coreInterfaces;
      publicEgressExitRulesFor =
        sourceScope: ingressPolicyIface:
        builtins.concatLists (
          map (
            exitPolicyIface:
            map (
              coreIface:
              {
                action = "accept";
                intent = {
                  kind = "runtime-routed-prefix-public-egress";
                  source = "intent-routed-prefix";
                  stage = "policy-to-public-uplink";
                };
                fromInterface = exitPolicyIface.runtimeIfName;
                toInterface = coreIface.runtimeIfName;
                inherit (sourceScope) sourceFiles sourcePrefixes;
                applyTcpMssClamp = false;
              }
              // (if sourceScope.sourceFiles != [ ] then { family = 6; } else { })
            ) (exitCoreInterfacesFor exitPolicyIface)
          ) (exitPolicyInterfacesFor ingressPolicyIface)
        );
    in
    builtins.concatLists (
      map (
        fromEntry:
        builtins.concatLists (
          map (
            toIface:
            if toIface.runtimeIfName == fromEntry.iface.runtimeIfName then
              [ ]
            else
              [
                (
                  {
                    action = "accept";
                    intent = {
                      kind = "runtime-routed-prefix-public-egress";
                      source = "intent-routed-prefix";
                      stage = "overlay-to-policy";
                    };
                    fromInterface = fromEntry.iface.runtimeIfName;
                    toInterface = toIface.runtimeIfName;
                    inherit (fromEntry) sourceFiles sourcePrefixes;
                    applyTcpMssClamp = false;
                  }
                  // (if fromEntry.sourceFiles != [ ] then { family = 6; } else { })
                )
              ]
              ++ publicEgressExitRulesFor fromEntry toIface
          ) (policyInterfacesForCore fromEntry.iface)
        )
      ) fromCoresWithSourceScopes
    );
}
