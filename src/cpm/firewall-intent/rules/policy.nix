{ common }:

{ endpointBindings
, relations
, services ? [ ]
, sharedServicePolicyAtoms ? [ ]
, trafficTypeMatches ? { }
, transitInterfaces
, runtimeOriginSourcePrefixes ? [ ]
}:
let
  endpointContext = import ./endpoint-context.nix { inherit common; } {
    inherit endpointBindings services transitInterfaces;
  };
  endpointSelection = import ./policy-endpoints.nix { inherit common endpointContext; };
  inherit (endpointContext) attrsOrEmpty listOrEmpty;
  inherit (endpointContext) serviceNamesForEndpoint serviceRecords uniqueStrings;
  inherit (endpointSelection) endpointIfaces endpointIfacesForPeerAccess;

  isNonEmptyString = value: builtins.isString value && value != "";

  relationId = relation:
    if builtins.isString (relation.id or null) && relation.id != "" then
      relation.id
    else if builtins.isString (relation.name or null) && relation.name != "" then
      relation.name
    else
      null;

  relationMatches = relation:
    if builtins.isList (relation.matches or null) then
      relation.matches
    else if builtins.isList (relation.match or null) then
      relation.match
    else
      trafficTypeMatches.${relation.trafficType or "any"} or [ ];

  discoverySurfaceMatch = surfaceRaw:
    let
      surface = attrsOrEmpty surfaceRaw;
      transport = surface.transport or null;
      port = surface.port or null;
    in
    if transport == "udp" && builtins.isInt port then
      {
        proto = "udp";
        family = "any";
        dports = [ port ];
      }
    else
      null;

  discoveryMatchesForAtom = atom:
    builtins.filter
      (match: match != null)
      (
        map discoverySurfaceMatch
          (listOrEmpty ((attrsOrEmpty (atom.discovery or null)).surfaces or null))
      );

  trafficTypeForAtom = atom: matches:
    let
      serviceName = atom.service or null;
      service =
        if isNonEmptyString serviceName then attrsOrEmpty (serviceRecords.${serviceName} or null) else { };
      serviceTrafficType = service.trafficType or null;
      serviceTrafficMatches =
        if isNonEmptyString serviceTrafficType then
          trafficTypeMatches.${serviceTrafficType} or [ ]
        else
          [ ];
    in
    if isNonEmptyString (atom.trafficType or null) then
      atom.trafficType
    else if isNonEmptyString serviceTrafficType && serviceTrafficMatches == matches then
      serviceTrafficType
    else
      "discovery";

  atomRequesters = atom:
    uniqueStrings (
      listOrEmpty (atom.requesterScopes or null)
      ++ listOrEmpty (atom.controllerScopes or null)
    );

  atomResponder = atom:
    if isNonEmptyString (atom.responderScope or null) then
      atom.responderScope
    else
      atom.receiverScope or null;

  sourcePrefixForAddress = family: address: {
    inherit family;
    prefix = address;
  };

  uniqueSourcePrefixes =
    prefixes:
    builtins.attrValues (
      builtins.listToAttrs (
        map
          (prefix: {
            name = "${builtins.toString (prefix.family or "")}|${prefix.prefix or ""}";
            value = prefix;
          })
          prefixes
      )
    );

  serviceSourcePrefixes =
    endpoint:
    uniqueSourcePrefixes (
      builtins.concatLists (
        map
          (serviceName:
            let
              service = attrsOrEmpty (serviceRecords.${serviceName} or null);
              providerEndpoints = listOrEmpty (service.providerEndpoints or null);
            in
            builtins.concatLists (
              map
                (providerEndpoint:
                  let
                    endpoint = attrsOrEmpty providerEndpoint;
                  in
                  map (sourcePrefixForAddress 4) (listOrEmpty (endpoint.ipv4 or null))
                  ++ map (sourcePrefixForAddress 6) (listOrEmpty (endpoint.ipv6 or null)))
                providerEndpoints
            ))
          (serviceNamesForEndpoint endpoint)
      )
    );

  withRelationSourceScope = relation: rule:
    let
      fromEndpoint = attrsOrEmpty (relation.from or null);
      prefixes =
        if (fromEndpoint.kind or null) == "service" then
          serviceSourcePrefixes fromEndpoint
        else
          [ ];
    in
    common.withSourcePrefixes rule prefixes;

  relationRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromIfaces = endpointIfaces relation (relation.from or null) (relation.to or null);
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      id = relationId relation;
    in
    builtins.concatLists (
      map
        (fromIface:
          let
            toIfaces =
              endpointIfacesForPeerAccess relation (relation.to or null) (relation.from or null) (common.laneAccess fromIface);
          in
          map
            (toIface:
              withRelationSourceScope relation {
                inherit action;
                relationId = id;
                comment = id;
                priority = relation.priority or null;
                trafficType = relation.trafficType or "any";
                direction = "relation-forward";
                matches = relationMatches relation;
                from = attrsOrEmpty (relation.from or null);
                to = attrsOrEmpty (relation.to or null);
                relationCardinality = {
                  unit = "policy-router-forwarding-rule";
                  decomposition = "decomposed-by-policy-interface-scope";
                  decomposed = true;
                };
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              }
              // (if builtins.isAttrs (relation.intent or null) then { intent = relation.intent; } else { })
              // (if isNonEmptyString (relation.comment or null) then { comment = relation.comment; } else { }))
            toIfaces)
        fromIfaces
    );

  sharedDiscoveryPolicyRules = atomRaw:
    let
      atom = attrsOrEmpty atomRaw;
      id = atom.id or null;
      matches = discoveryMatchesForAtom atom;
      responder = atomResponder atom;
      requesters = atomRequesters atom;
    in
    if !isNonEmptyString id || !isNonEmptyString responder || matches == [ ] then
      [ ]
    else
      builtins.concatLists (
        map
          (requester:
            relationRules {
              action = "allow";
              from = {
                kind = "tenant";
                name = requester;
              };
              id = id;
              priority = atom.priority or 119;
              to = {
                kind = "tenant";
                name = responder;
              };
              trafficType = trafficTypeForAtom atom matches;
              inherit matches;
              intent = {
                kind = "shared-service-discovery-policy";
                policyAtomId = id;
                service = atom.service or null;
                serviceClass = atom.serviceClass or null;
                sms = atom.sms or null;
                source = attrsOrEmpty (atom.source or null);
              };
              comment = "shared-service-discovery-policy:${id}";
            })
          requesters
      );
in
builtins.concatLists (map relationRules (listOrEmpty relations))
++ builtins.concatLists (map sharedDiscoveryPolicyRules (listOrEmpty sharedServicePolicyAtoms))
++ common.runtimeOriginDefaultForwardRulesWith {
  inherit runtimeOriginSourcePrefixes;
  interfaces = transitInterfaces;
  isIngressIface = iface: common.laneKind iface == "access";
  isDefaultIface = iface: common.laneKind iface == "access-uplink";
}
