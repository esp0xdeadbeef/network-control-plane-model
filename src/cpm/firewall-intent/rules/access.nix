{ common }:

{ endpointBindings ? { }
, localInterfaces
, relations ? [ ]
, services ? [ ]
, targetLogicalNode ? null
, trafficPaths ? [ ]
, trafficTypeMatches ? { }
, transitInterfaces
, runtimeOriginSourcePrefixes ? [ ]
, tenantPrefixOwners ? { }
}:
let
  endpointContext = import ./endpoint-context.nix { inherit common; } {
    inherit endpointBindings services transitInterfaces;
  };
  inherit (endpointContext)
    accessNodesForEndpoint
    attrsOrEmpty
    listOrEmpty
    runtimeInterfacesForEndpointAtLogicalNode
    sourcePrefixesForEndpoint
    ;

  # Tenant prefixes owned by this site; used to make the access local-to-fabric
  # handoff enforceable (the local tenant surface and the fabric p2p are both
  # host-bridge realized, so they cannot carry a dedicated-link isolation
  # proof).
  allTenantPrefixes =
    builtins.map
      (key:
        let
          parts = builtins.split "\\|" key;
          familyPart = builtins.elemAt parts 0;
          prefixPart = builtins.elemAt parts 2;
        in
        {
          family = if familyPart == "6" then 6 else 4;
          prefix = prefixPart;
        })
      (builtins.attrNames tenantPrefixOwners);

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

  pathTerminatesAtTargetAccess = relation:
    let
      id = relationId relation;
    in
    id != null
    && builtins.any
      (path:
        let
          nodePath = if builtins.isList (path.nodePath or null) then path.nodePath else [ ];
          stagePath = if builtins.isList (path.stagePath or null) then path.stagePath else [ ];
          count = builtins.length nodePath;
        in
        builtins.isAttrs path
        && (path.relationId or null) == id
        && count >= 2
        && builtins.length stagePath == count
        && builtins.elemAt nodePath (count - 1) == targetLogicalNode
        && builtins.elemAt nodePath (count - 2) == "downstream-selector"
        && builtins.elemAt stagePath (count - 1) == "access"
        && builtins.elemAt stagePath (count - 2) == "downstream-selector")
      trafficPaths;

  accessTransitInterfaces =
    builtins.filter
      (iface:
        common.laneKind iface == "access-edge"
        && common.laneAccess iface == targetLogicalNode)
      transitInterfaces;

  relationIngressRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      id = relationId relation;
      toEndpoint = attrsOrEmpty (relation.to or null);
      destinationRuntimeInterfaces =
        runtimeInterfacesForEndpointAtLogicalNode toEndpoint targetLogicalNode;
      destinationInterfaces =
        builtins.filter
          (iface: builtins.elem iface.runtimeIfName destinationRuntimeInterfaces)
          localInterfaces;
      sourcePrefixes = sourcePrefixesForEndpoint (relation.from or null);
      direction = "relation-forward-access-ingress";
    in
    if
      (relation.action or "allow") == "deny"
      || id == null
      || targetLogicalNode == null
      || !(builtins.elem targetLogicalNode (accessNodesForEndpoint toEndpoint))
      || !(pathTerminatesAtTargetAccess relation)
    then
      [ ]
    else
      builtins.concatLists (
        map
          (transitIface:
            map
              (destinationIface:
                common.withSourcePrefixes
                  ({
                    action = "accept";
                    relationId = id;
                    comment = id;
                    priority = relation.priority or null;
                    trafficType = relation.trafficType or "any";
                    inherit direction;
                    matches = relationMatches relation;
                    from = attrsOrEmpty (relation.from or null);
                    to = toEndpoint;
                    transportAuthority = {
                      basis = "modeled-relation";
                      provenanceIsAuthority = false;
                      admissible = true;
                    };
                    relationCardinality = {
                      unit = "access-forwarding-rule";
                      decomposition = "decomposed-by-explicit-destination-access-path-leg";
                      decomposed = true;
                    };
                    fromInterface = transitIface.runtimeIfName;
                    toInterface = destinationIface.runtimeIfName;
                    applyTcpMssClamp = false;
                  }
                  // common.relationHandoff {
                    relationId = id;
                    action = "accept";
                    inherit direction;
                    fromIface = transitIface;
                    toIface = destinationIface;
                    policyPoint = "access-edge";
                  })
                  sourcePrefixes)
              destinationInterfaces)
          accessTransitInterfaces
      );
in
builtins.concatLists (
  builtins.map
    (localIface:
    builtins.concatLists (
      builtins.map
        (transitIface: common.selectorPairRuleWithSourcePrefixes allTenantPrefixes localIface transitIface)
        transitInterfaces
    ))
    localInterfaces
)
++ builtins.concatLists (map relationIngressRules (listOrEmpty relations))
++ common.runtimeOriginDefaultForwardRules runtimeOriginSourcePrefixes transitInterfaces
