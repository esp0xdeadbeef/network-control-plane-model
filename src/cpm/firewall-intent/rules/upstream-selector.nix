{ common }:

{
  transitInterfaces,
  relations ? [ ],
}:
let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];

  coreInterfaces =
    builtins.filter
      (iface: common.uplinks iface != [ ] && common.laneKind iface == "uplink")
      transitInterfaces;

  policyInterfaces =
    builtins.filter
      (iface: common.laneKind iface == "access-uplink" && common.laneUplink iface != null)
      transitInterfaces;

  familyRoutes = routes:
    listOrEmpty (routes.ipv4 or null) ++ listOrEmpty (routes.ipv6 or null);

  routeIntent = route: attrsOrEmpty (route.intent or null);

  runtimeRoutedPrefixSourceFiles = iface:
    builtins.filter
      (sourceFile: builtins.isString sourceFile && sourceFile != "")
      (
        builtins.map
          (route: route.sourceFile or null)
          (builtins.filter
            (route:
              builtins.isAttrs route
              && ((routeIntent route).kind or null) == "runtime-routed-prefix-return")
            (familyRoutes (attrsOrEmpty (iface.routes or null))))
      );

  coreForPolicy = policyIface:
    let
      matchesCore =
        builtins.filter
          (coreIface: builtins.elem (common.laneUplink policyIface) (common.uplinks coreIface))
          coreInterfaces;
    in
    if matchesCore == [ ] then null else builtins.elemAt matchesCore 0;

  externalUplinks = endpoint:
    let
      value = attrsOrEmpty endpoint;
    in
    if (value.kind or null) != "external" then
      [ ]
    else
      (listOrEmpty (value.uplinks or null))
      ++ (if value ? name then [ value.name ] else [ ]);

  coreInterfacesFor = endpoint:
    let
      wanted = externalUplinks endpoint;
    in
    builtins.filter
      (iface: builtins.any (uplink: builtins.elem uplink (common.uplinks iface)) wanted)
      coreInterfaces;

  externalTransitRule = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromCores = coreInterfacesFor (relation.from or null);
      toCores = coreInterfacesFor (relation.to or null);
      trafficType = relation.trafficType or "any";
      action = relation.action or "allow";
      fromExternal = attrsOrEmpty (relation.from or null);
      toExternal = attrsOrEmpty (relation.to or null);
      fromIsNamedOverlay =
        (fromExternal.kind or null) == "external"
        && fromExternal ? name
        && !(fromExternal ? uplinks);
      toIsWanUplink =
        (toExternal.kind or null) == "external"
        && builtins.isList (toExternal.uplinks or null);
    in
    if action != "allow" || trafficType == "any" || (fromIsNamedOverlay && toIsWanUplink) then
      [ ]
    else
      builtins.concatLists (
        builtins.map
          (fromIface:
            builtins.map
              (toIface: {
                action = "accept";
                relationId = relation.id or null;
                priority = relation.priority or null;
                inherit trafficType;
                from = attrsOrEmpty (relation.from or null);
                to = attrsOrEmpty (relation.to or null);
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              })
              toCores)
          fromCores
      );

  hasOverlayUnderlayEndpointRoute = overlayName: iface:
    let routes = familyRoutes (attrsOrEmpty (iface.routes or null));
    in
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.overlay or null) == overlayName
        && (route.proto or null) == "underlay"
        && ((routeIntent route).kind or null) == "overlay-underlay-reachability")
      routes;

  overlayUnderlayTransitRule = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromExternal = attrsOrEmpty (relation.from or null);
      toExternal = attrsOrEmpty (relation.to or null);
      trafficType = relation.trafficType or "any";
      action = relation.action or "allow";
      overlayName = fromExternal.name or null;
      fromCores = coreInterfacesFor fromExternal;
      toCores =
        builtins.filter
          (iface: overlayName != null && hasOverlayUnderlayEndpointRoute overlayName iface)
          (coreInterfacesFor toExternal);
      fromIsNamedOverlay =
        (fromExternal.kind or null) == "external"
        && fromExternal ? name
        && !(fromExternal ? uplinks);
      toIsWanUplink =
        (toExternal.kind or null) == "external"
        && builtins.isList (toExternal.uplinks or null);
    in
    if action != "allow" || trafficType == "any" || !fromIsNamedOverlay || !toIsWanUplink then
      [ ]
    else
      builtins.concatLists (
        builtins.map
          (fromIface:
            builtins.map
              (toIface: {
                action = "accept";
                relationId = relation.id or null;
                priority = relation.priority or null;
                inherit trafficType;
                intent = {
                  kind = "overlay-underlay-reachability";
                  source = "overlay-underlay-endpoint";
                  overlay = overlayName;
                };
                from = fromExternal;
                to = toExternal;
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              })
              toCores)
          fromCores
      );

  runtimeRoutedPrefixPublicEgressRules =
    let
      fromCoresWithSourceFiles =
        builtins.filter (entry: entry.sourceFiles != [ ]) (
          builtins.map
            (iface: {
              inherit iface;
              sourceFiles = runtimeRoutedPrefixSourceFiles iface;
            })
            coreInterfaces
        );
    in
    builtins.concatLists (
      builtins.map
        (fromEntry:
          builtins.concatLists (
            builtins.map
              (toIface:
                if toIface.runtimeIfName == fromEntry.iface.runtimeIfName then
                  [ ]
                else
                  [
                    {
                      action = "accept";
                      intent = {
                        kind = "runtime-routed-prefix-public-egress";
                        source = "inventory-routed-prefix";
                      };
                      fromInterface = fromEntry.iface.runtimeIfName;
                      toInterface = toIface.runtimeIfName;
                      sourceFiles = fromEntry.sourceFiles;
                      family = 6;
                      applyTcpMssClamp = false;
                    }
                  ])
              coreInterfaces
          ))
        fromCoresWithSourceFiles
    );
in
  (builtins.concatLists (
    builtins.map
      (policyIface:
        let
          coreIface = coreForPolicy policyIface;
        in
        if coreIface == null then [ ] else common.selectorPairRule policyIface coreIface)
      policyInterfaces
  ))
  ++ (builtins.concatLists (builtins.map externalTransitRule relations))
  ++ (builtins.concatLists (builtins.map overlayUnderlayTransitRule relations))
  ++ runtimeRoutedPrefixPublicEgressRules
