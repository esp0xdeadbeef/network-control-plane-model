{ common, endpointContext, trafficTypeMatches ? { } }:

let
  inherit (endpointContext)
    attrsOrEmpty
    listOrEmpty
    transitInterfaces
    coreInterfaces
    policyInterfaces
    serviceAccessNodes
    serviceNamesForEndpoint
    serviceRecords
    uniqueStrings
    ;

  familyRoutes = routes: listOrEmpty (routes.ipv4 or null) ++ listOrEmpty (routes.ipv6 or null);

  routeIntent = route: attrsOrEmpty (route.intent or null);

  relationMatches = relation:
    if builtins.isList (relation.matches or null) then
      relation.matches
    else if builtins.isList (relation.match or null) then
      relation.match
    else
      trafficTypeMatches.${relation.trafficType or "any"} or [ ];

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
      endpointValue = attrsOrEmpty endpoint;
      namedExternalOverlayIngress = builtins.filter (
        iface:
        (endpointValue.kind or null) == "external"
        && endpointValue ? name
        && !(endpointValue ? uplinks)
        && common.laneKind iface != "access-uplink"
        && builtins.any (uplink: builtins.elem uplink (common.uplinks iface)) wanted
      ) transitInterfaces;
      matches = builtins.filter (
        iface: builtins.any (uplink: builtins.elem uplink (common.uplinks iface)) wanted
      ) (coreInterfaces ++ policyInterfaces);
    in
    if namedExternalOverlayIngress != [ ] then
      namedExternalOverlayIngress
    else
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

  serviceResponseSourcePrefixes = import ./service-response-prefixes.nix {
    inherit
      listOrEmpty
      serviceNamesForEndpoint
      serviceRecords
      uniqueStrings
      ;
  };

  pairRules =
    relation: fromIfaces: toIfaces: extra:
    let
      trafficType = relation.trafficType or "any";
      action = "accept";
      direction = "relation-forward";
    in
    builtins.concatLists (
      map (
        fromIface:
        map (
          toIface:
          {
            inherit action;
            relationId = relation.id or null;
            comment =
              if builtins.isString (relation.id or null) then
                relation.id
              else if builtins.isString (relation.name or null) then
                relation.name
              else
                null;
            priority = relation.priority or null;
            inherit trafficType;
            inherit direction;
            matches = relationMatches relation;
            from = attrsOrEmpty (relation.from or null);
            to = attrsOrEmpty (relation.to or null);
            # FS-270-HDS-010-SDS-010-SMS-040: this accept is authorized by an
            # explicitly modeled intent relation, not by interface fanout or
            # provenance labels.
            transportAuthority = {
              basis = "modeled-relation";
              provenanceIsAuthority = false;
              admissible = true;
            };
            relationCardinality = {
              unit = "selector-forwarding-rule";
              decomposition = "decomposed-by-selector-interface-scope";
              decomposed = true;
            };
            fromInterface = fromIface.runtimeIfName;
            toInterface = toIface.runtimeIfName;
            applyTcpMssClamp = false;
          }
          // common.relationHandoff {
            relationId = relation.id or null;
            inherit action direction fromIface toIface;
            policyPoint = "upstream-selector";
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

  overlayUnderlayTransitRule = import ./upstream-selector-overlay-underlay.nix {
    inherit
      common
      endpointContext
      familyRoutes
      routeIntent
      coreInterfacesFor
      pairRules
      ;
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
      let
        ingressIfaces = externalIngressInterfacesFor fromEndpoint;
        serviceIfaces = servicePolicyInterfacesForExternal fromEndpoint toEndpoint;
        responseSourcePrefixes = serviceResponseSourcePrefixes toEndpoint;
        responseRules =
          if (relation.trafficType or null) != "dns" || responseSourcePrefixes == [ ] then
            [ ]
          else
            pairRules relation serviceIfaces ingressIfaces {
              sourcePrefixes = responseSourcePrefixes;
            };
      in
      (pairRules relation ingressIfaces serviceIfaces { }) ++ responseRules;

  runtimeRoutedPrefixPublicEgressRules = import ./upstream-selector-runtime-prefix-egress.nix {
    inherit
      common
      endpointContext
      familyRoutes
      routeIntent
      ;
  };
}
