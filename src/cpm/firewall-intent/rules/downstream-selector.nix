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

  # The node immediately AFTER this router on a policy-required path.
  #
  # policyEgressRules can only express a relation whose path continues to an
  # access node (stagePath[i+2] == "access"), and localRelationRules only handles
  # relations needing no policy. A service hosted on a core satisfies neither: its
  # path is
  #   [ "access-clients" "downstream-selector" "policy" "upstream-selector" "core" ]
  # so policy is followed by upstream-selector, never an access node, and the
  # relation produced no rule at all -- the DS policy-drop chain then silently
  # discarded the access resolver's query.
  #
  # The next hop is already modelled, so it does not have to be inferred.
  nextHopAfterSelector =
    relation:
    let
      id = relationId relation;
      step =
        rest:
        if rest == [ ] then
          null
        else if builtins.head rest == "downstream-selector" then
          if builtins.length rest >= 2 then builtins.elemAt rest 1 else null
        else
          step (builtins.tail rest);
      candidates = builtins.filter (
        path: builtins.isAttrs path && (path.relationId or null) == id && (path.requiresPolicy or false) == true
      ) trafficPaths;
      nextHops = builtins.foldl' (
        acc: path:
        let h = step (path.nodePath or [ ]);
        in if h == null || builtins.elem h acc then acc else acc ++ [ h ]
      ) [ ] candidates;
    in
    if id == null || nextHops == [ ] then null else builtins.head nextHops;

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
                # FS-270-HDS-010-SDS-010-SMS-040 / FS-310-HDS-040-SDS-010-SMS-170:
                # an unclassified (trafficType = any) interface-pair transport
                # accept is admissible only with a complete dedicated-link
                # isolation proof; a rule that preserves modeled matches is
                # admissible as enforceable-matches. A bare "modeled-relation"
                # label is topology provenance, not packet authority.
                transportAuthority = common.selectorTransportAuthority {
                  inherit fromIface toIface;
                  trafficType = relation.trafficType or "any";
                  sourcePrefixes = [ ];
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
                        priority = relation.priority or null;
                        trafficType = relation.trafficType or "any";
                        matches = relationMatches relation;
                        from = attrsOrEmpty (relation.from or null);
                        to = attrsOrEmpty (relation.to or null);
                        # FS-275-HDS-010-SDS-010-SMS-010 / FS-310-HDS-040-SDS-010-SMS-170:
                        # every selector edge, including the stateful reverse
                        # leg, must carry its own relation identity, traffic
                        # class and transport authority. This leg is a bounded
                        # established,related return, so its authority basis is
                        # stateful-return and not inherited from the forward
                        # leg's modeled-relation record.
                        direction = "relation-reverse-access-ingress";
                        transportAuthority = common.selectorTransportAuthority {
                          inherit fromIface toIface;
                          trafficType = relation.trafficType or "any";
                          statefulReturn = true;
                        };
                        relationCardinality = {
                          unit = "selector-forwarding-rule";
                          decomposition = "decomposed-by-explicit-policy-ingress-path-leg";
                          decomposed = true;
                        };
                      }
                      // common.relationHandoff {
                        relationId = id;
                        action = "accept";
                        direction = "relation-reverse-access-ingress";
                        # The reverse leg runs policy-egress -> source access, so
                        # the traversal endpoints must mirror the rule record
                        # (fromInterface = toPolicyIface, toInterface = fromIface)
                        # exactly. Naming the outer `toIface` here made
                        # policyPointTraversal.destinationInterface disagree with
                        # the rule's toInterface and stripped the leg of its
                        # forwarding-model origin.
                        fromIface = toPolicyIface;
                        toIface = fromIface;
                        policyPoint = "downstream-selector";
                      })
                    ])
                  fromIfaces
              )
          )
          toIfaces
      );

  # A policy-required relation whose path leaves this router toward a NON-access
  # node (a service hosted on a core). Neither arm above can express it, so the
  # rule was never emitted and the DS policy-drop chain silently discarded the
  # packet -- the access resolver's query to the core resolver died here, which is
  # why name resolution failed while the site's own egress worked.
  #
  # Emit from = the access-edge lane whose owner is the relation source, out = the
  # fabric lane whose peer is the next node on the modelled path. Both the next
  # hop and the lanes are already in the model; nothing is inferred.
  nonAccessEgressRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      id = relationId relation;
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      direction = "relation-forward-policy-egress";
      nextHop = nextHopAfterSelector relation;
      fromIfaces = accessIfacesForEndpoint (relation.from or null);
      # Fabric lanes of this router: p2p links toward policy.
      fabricIfaces = builtins.filter (
        iface: common.laneKind iface == "access" && common.laneAccess iface != null
      ) transitInterfaces;
      # Only the fabric lane paired with the source access lane: the relation is
      # scoped to one access scope, and emitting every fabric lane would grant
      # the same authority on seven unrelated lanes.
      sourceAccess = builtins.head (
        builtins.filter (x: x != null) (map common.laneAccess fromIfaces)
      );
      toIfaces = builtins.filter (
        iface: sourceAccess != null && common.laneAccess iface == sourceAccess
      ) fabricIfaces;
    in
    if
      !(relationRequiresPolicy relation)
      || nextHop == null
      # FS-260: policy-required ACCESS-to-ACCESS traffic must not bypass policy.
      # That is `policyEgressRules`' job; this arm exists only for a destination
      # that is not an access node (a service hosted on the core), so refuse to
      # emit anything when the destination does resolve to access nodes.
      || accessIfacesForEndpoint (relation.to or null) != [ ]
      || fromIfaces == [ ]
      || toIfaces == [ ]
    then
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
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              }
              // common.relationHandoff {
                relationId = id;
                inherit action direction fromIface toIface;
                policyPoint = "downstream-selector";
              })
              toIfaces)
          fromIfaces
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
++ builtins.concatLists (map nonAccessEgressRules (listOrEmpty relations))
++ common.runtimeOriginDefaultForwardRules runtimeOriginSourcePrefixes transitInterfaces
