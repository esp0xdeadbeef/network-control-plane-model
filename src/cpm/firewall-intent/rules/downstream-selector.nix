{ common }:

{ endpointBindings ? { }
, transitInterfaces
, relations ? [ ]
, services ? [ ]
, trafficTypeMatches ? { }
, runtimeOriginSourcePrefixes ? [ ]
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

  relationMatches = relation:
    if builtins.isList (relation.matches or null) then
      relation.matches
    else if builtins.isList (relation.match or null) then
      relation.match
    else
      trafficTypeMatches.${relation.trafficType or "any"} or [ ];

  localRelationRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromIfaces = accessIfacesForEndpoint (relation.from or null);
      toIfaces = accessIfacesForEndpoint (relation.to or null);
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      id = relationId relation;
      direction = "relation-forward";
    in
    builtins.concatLists (
      map
        (fromIface:
          map
            (toIface: {
              inherit action;
              relationId = id;
              comment = id;
              priority = relation.priority or null;
              trafficType = relation.trafficType or "any";
              inherit direction;
              matches = relationMatches relation;
              from = attrsOrEmpty (relation.from or null);
              to = attrsOrEmpty (relation.to or null);
              # FS-270-HDS-010-SDS-010-SMS-040: this accept is authorized by
              # an explicitly modeled intent relation, not by interface
              # fanout or provenance labels.
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
              relationId = id;
              inherit action direction fromIface toIface;
              policyPoint = "downstream-selector";
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
    if policyIface == null then
      [ ]
    else
      common.selectorPairRule accessIface policyIface
      ++ common.selectorPairRuleWithRuntimeOriginScope runtimeOriginSourcePrefixes accessIface policyIface)
    accessInterfaces
)
++ builtins.concatLists (map localRelationRules (listOrEmpty relations))
++ common.runtimeOriginDefaultForwardRules runtimeOriginSourcePrefixes transitInterfaces
