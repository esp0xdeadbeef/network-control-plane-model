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

  runtimeRoutedPrefixPublicEgressRules = import ./upstream-selector-runtime-prefix-egress.nix {
    inherit
      common
      endpointContext
      familyRoutes
      routeIntent
      ;
  };
}
