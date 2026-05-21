{ common }:

{ endpointBindings ? { }
, transitInterfaces
, relations ? [ ]
, services ? [ ]
,
}:
let
  endpointContext = import ./endpoint-context.nix { inherit common; } {
    inherit endpointBindings services transitInterfaces;
  };
  inherit (endpointContext) accessNodesForEndpoint attrsOrEmpty listOrEmpty;

  accessInterfaces =
    builtins.filter
      (iface: common.laneKind iface == "access-edge" && common.laneAccess iface != null)
      transitInterfaces;

  policyInterfaces =
    builtins.filter
      (iface: common.laneKind iface == "access" && common.laneAccess iface != null)
      transitInterfaces;

  policyForAccess = accessIface:
    let
      matchesPolicy =
        builtins.filter
          (policyIface: common.laneAccess policyIface == common.laneAccess accessIface)
          policyInterfaces;
    in
    if matchesPolicy == [ ] then null else builtins.elemAt matchesPolicy 0;

  accessInterfaceByNode =
    builtins.listToAttrs (
      map (iface: {
        name = common.laneAccess iface;
        value = iface;
      }) accessInterfaces
    );

  accessIfacesForEndpoint = endpoint:
    builtins.filter (iface: iface != null) (
      map
        (node:
          if builtins.hasAttr node accessInterfaceByNode then
            accessInterfaceByNode.${node}
          else
            null)
        (accessNodesForEndpoint endpoint)
    );

  relationId = relation:
    if builtins.isString (relation.id or null) && relation.id != "" then
      relation.id
    else if builtins.isString (relation.name or null) && relation.name != "" then
      relation.name
    else
      null;

  localRelationRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromIfaces = accessIfacesForEndpoint (relation.from or null);
      toIfaces = accessIfacesForEndpoint (relation.to or null);
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      id = relationId relation;
    in
    builtins.concatLists (
      map
        (fromIface:
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
            (builtins.filter (toIface: toIface.runtimeIfName != fromIface.runtimeIfName) toIfaces))
        fromIfaces
    );
in
builtins.concatLists (
  builtins.map
    (accessIface:
    let
      policyIface = policyForAccess accessIface;
    in
    if policyIface == null then [ ] else common.selectorPairRule accessIface policyIface)
    accessInterfaces
)
++ builtins.concatLists (map localRelationRules (listOrEmpty relations))
