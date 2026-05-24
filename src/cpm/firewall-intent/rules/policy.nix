{ common }:

{ endpointBindings, relations, services ? [ ], transitInterfaces, runtimeOriginSourcePrefixes ? [ ] }:
let
  endpointContext = import ./endpoint-context.nix { inherit common; } {
    inherit endpointBindings services transitInterfaces;
  };
  endpointSelection = import ./policy-endpoints.nix { inherit common endpointContext; };
  inherit (endpointContext) attrsOrEmpty listOrEmpty;
  inherit (endpointSelection) endpointIfaces endpointIfacesForPeerAccess;

  relationId = relation:
    if builtins.isString (relation.id or null) && relation.id != "" then
      relation.id
    else if builtins.isString (relation.name or null) && relation.name != "" then
      relation.name
    else
      null;

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
            (toIface: {
              inherit action;
              relationId = id;
              priority = relation.priority or null;
              trafficType = relation.trafficType or "any";
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
