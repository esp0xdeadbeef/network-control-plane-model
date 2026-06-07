{ common }:

{ endpointBindings
, relations
, services ? [ ]
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
  inherit (endpointContext) serviceNamesForEndpoint serviceRecords;
  inherit (endpointSelection) endpointIfaces endpointIfacesForPeerAccess;

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
                priority = relation.priority or null;
                trafficType = relation.trafficType or "any";
                matches = relationMatches relation;
                from = attrsOrEmpty (relation.from or null);
                to = attrsOrEmpty (relation.to or null);
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              })
            toIfaces)
        fromIfaces
    );
in
builtins.concatLists (map relationRules (listOrEmpty relations))
++ common.runtimeOriginDefaultForwardRulesWith {
  inherit runtimeOriginSourcePrefixes;
  interfaces = transitInterfaces;
  isIngressIface = iface: common.laneKind iface == "access";
  isDefaultIface = iface: common.laneKind iface == "access-uplink";
}
