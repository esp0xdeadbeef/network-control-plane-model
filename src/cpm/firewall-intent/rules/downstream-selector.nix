{ common }:

{ endpointBindings ? { }
, transitInterfaces
, relations ? [ ]
, services ? [ ]
, trafficPaths ? [ ]
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
      map
        (iface: {
          name = common.laneAccess iface;
          value = iface;
        })
        accessInterfaces
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

  relationRequiresPolicy =
    relation:
    let
      id = relationId relation;
    in
    id != null
    && (relation.action or "allow") != "deny"
    && builtins.any
      (
        path:
        builtins.isAttrs path
        && (path.relationId or null) == id
        && (path.requiresPolicy or false) == true
      )
      trafficPaths;

  pathContainsPolicyEgressToAccess = relation: accessNode:
    let
      id = relationId relation;
    in
    id != null
    && builtins.any
      (
        path:
        let
          nodePath = if builtins.isList (path.nodePath or null) then path.nodePath else [ ];
          stagePath = if builtins.isList (path.stagePath or null) then path.stagePath else [ ];
          nodeCount = builtins.length nodePath;
          stageCount = builtins.length stagePath;
          candidateIndexes =
            builtins.genList (index: index) (
              if nodeCount < 3 || stageCount != nodeCount then 0 else nodeCount - 2
            );
        in
        builtins.isAttrs path
        && (path.relationId or null) == id
        && (path.requiresPolicy or false) == true
        && builtins.any
          (
            index:
            builtins.elemAt stagePath index == "policy"
            && builtins.elemAt stagePath (index + 1) == "downstream-selector"
            && builtins.elemAt stagePath (index + 2) == "access"
            && builtins.elemAt nodePath (index + 2) == accessNode
          )
          candidateIndexes
      )
      trafficPaths;

  localRelationRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromIfaces = accessIfacesForEndpoint (relation.from or null);
      toIfaces = accessIfacesForEndpoint (relation.to or null);
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      id = relationId relation;
      direction = "relation-forward";
    in
    if relationRequiresPolicy relation then
      [ ]
    else
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

  # FS-315-HDS-010-SDS-010-SMS-040: on the downstream-selector, a
  # policy-routed lateral relation (source access -> policy -> destination
  # access) has two selector legs per direction. The source-access -> the
  # destination access's policy-egress lane leg carries the forward packet in,
  # and its stateful reverse mirrors it. Without this leg the selector's
  # default-drop forward chain drops the lateral packet, even though the route
  # resolves it toward the destination policy-egress lane.
  policyIngressRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromIfaces = accessIfacesForEndpoint (relation.from or null);
      toIfaces = accessIfacesForEndpoint (relation.to or null);
      id = relationId relation;
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      direction = "relation-forward-access-ingress";
    in
    if action != "accept" || !(relationRequiresPolicy relation) then
      [ ]
    else
      builtins.concatLists (
        map
          (
            toIface:
            let
              toPolicyIface = policyForAccess toIface;
              toAccessNode = common.laneAccess toIface;
            in
            if
              toPolicyIface == null
              || toAccessNode == null
              || !(pathContainsPolicyEgressToAccess relation toAccessNode)
            then
              [ ]
            else
              builtins.concatLists (
                map
                  (fromIface:
                    [
                      ({
                        inherit action;
                        relationId = id;
                        comment = id;
                        priority = relation.priority or null;
                        trafficType = relation.trafficType or "any";
                        inherit direction;
                        matches = relationMatches relation;
                        from = attrsOrEmpty (relation.from or null);
                        to = attrsOrEmpty (relation.to or null);
                        transportAuthority = {
                          basis = "modeled-relation";
                          provenanceIsAuthority = false;
                          admissible = true;
                        };
                        relationCardinality = {
                          unit = "selector-forwarding-rule";
                          decomposition = "decomposed-by-explicit-policy-ingress-path-leg";
                          decomposed = true;
                        };
                        fromInterface = fromIface.runtimeIfName;
                        toInterface = toPolicyIface.runtimeIfName;
                        applyTcpMssClamp = false;
                      }
                      // common.relationHandoff {
                        relationId = id;
                        inherit action direction fromIface;
                        toIface = toPolicyIface;
                        policyPoint = "downstream-selector";
                      })
                      ({
                        action = "accept";
                        fromInterface = toPolicyIface.runtimeIfName;
                        toInterface = fromIface.runtimeIfName;
                        applyTcpMssClamp = false;
                        connectionState = "established,related";
                        returnRule = true;
                        relationId = id;
                        comment = id;
                      }
                      // common.relationHandoff {
                        relationId = id;
                        action = "accept";
                        direction = "relation-reverse-access-ingress";
                        fromIface = toPolicyIface;
                        inherit toIface;
                        policyPoint = "downstream-selector";
                      })
                    ])
                  fromIfaces
              )
          )
          toIfaces
      );

  policyEgressRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      toIfaces = accessIfacesForEndpoint (relation.to or null);
      id = relationId relation;
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      direction = "relation-forward-policy-egress";
    in
    if action != "accept" || !(relationRequiresPolicy relation) then
      [ ]
    else
      builtins.concatLists (
        map
          (
            toIface:
            let
              policyIface = policyForAccess toIface;
              accessNode = common.laneAccess toIface;
            in
            if
              policyIface == null
              || accessNode == null
              || !(pathContainsPolicyEgressToAccess relation accessNode)
            then
              [ ]
            else
              [
                ({
                  inherit action;
                  relationId = id;
                  comment = id;
                  priority = relation.priority or null;
                  trafficType = relation.trafficType or "any";
                  inherit direction;
                  matches = relationMatches relation;
                  from = attrsOrEmpty (relation.from or null);
                  to = attrsOrEmpty (relation.to or null);
                  transportAuthority = {
                    basis = "modeled-relation";
                    provenanceIsAuthority = false;
                    admissible = true;
                  };
                  relationCardinality = {
                    unit = "selector-forwarding-rule";
                    decomposition = "decomposed-by-explicit-policy-egress-path-leg";
                    decomposed = true;
                  };
                  fromInterface = policyIface.runtimeIfName;
                  toInterface = toIface.runtimeIfName;
                  applyTcpMssClamp = false;
                }
                // common.relationHandoff {
                  relationId = id;
                  inherit action direction;
                  fromIface = policyIface;
                  inherit toIface;
                  policyPoint = "downstream-selector";
                })
              ]
          )
          toIfaces
      );
in
builtins.concatLists
  (
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
++ builtins.concatLists (map policyIngressRules (listOrEmpty relations))
++ builtins.concatLists (map policyEgressRules (listOrEmpty relations))
++ common.runtimeOriginDefaultForwardRules runtimeOriginSourcePrefixes transitInterfaces
