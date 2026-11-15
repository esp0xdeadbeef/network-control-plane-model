{
  requireString,
  bgpSiteAsn,
  bgpNeighborsForNode,
  ebgpNeighborsForTarget,
  bgpNetworksForNode,
}:

{
  nodePath,
  nodeName,
  nodeAttrs,
  # FS-322-HDS-010-SDS-010-SMS-020 resolves a selection to the *selected scope
  # offered prefixes*, which needs the sibling nodes. Only the full
  # build-target pass has them; a focused caller that constructs one target in
  # isolation (the FS-250-SMS-010 case imports this file directly) has no
  # siblings to give. Default to none, so the contract stays "resolve against
  # whatever siblings are supplied" instead of turning the parameter into a
  # hard requirement that breaks every isolated caller.
  peerNodeAttrs ? { },
  logical,
  isBgpRouter,
  placement,
  loopback,
  effectiveRuntimeInterfaces,
  nodeRole,
  runtimeContainers,
  runtimeOriginEgressContract,
  runtimeServices,
  hasRuntimeServices,
  runtimeStatePolicy,
  runtimeDiagnostics,
}:
let
  offersOf =
    name:
    let
      peer = peerNodeAttrs.${name} or null;
      offered = if builtins.isAttrs peer then (peer.offers or [ ]) else [ ];
    in
    if builtins.isList offered then offered else [ ];

  # Topology collections are sets in the compiled site data and lists in
  # hand-built fixtures. Normalize before filtering; `builtins.filter` on an
  # attribute set is a type error, not an empty result.
  asList =
    value:
    if builtins.isList value then value
    else if builtins.isAttrs value then builtins.attrValues value
    else [ ];

  # FS-322-HDS-010-SDS-010-SMS-020: a selection is emitted as the ordered
  # selected scopes *together with their member uplinks*. The member uplinks of
  # a scope are the uplinks it owns -- declared on the node itself, or, for a
  # scope that is an uplink rather than a node, the lanes that carry it.
  uplinksOfNode =
    name:
    let
      peer = peerNodeAttrs.${name} or null;
      declared = if builtins.isAttrs peer then (peer.uplinks or null) else null;
      fromLanes = builtins.concatLists (
        builtins.map (
          node: builtins.filter (uplink: builtins.isString uplink) (
            map (iface: iface.uplink or null) (builtins.filter builtins.isAttrs (asList (node.interfaces or [ ])))
            ++ builtins.map (iface: iface.uplink or null) (builtins.filter builtins.isAttrs (asList (node.uplinks or [ ])))
          )
        ) (builtins.filter builtins.isAttrs (builtins.attrValues peerNodeAttrs))
      );
      names =
        if builtins.isAttrs declared then
          builtins.attrNames declared
        else if builtins.isList declared then
          builtins.filter builtins.isString declared
        else
          [ ];
    in
    if names != [ ] then names else if name == "" then [ ] else builtins.filter (u: u == name) fromLanes;

  selectedScopeOf =
    entry:
    if builtins.isAttrs entry then
      (entry.scope or entry.surface or entry.uplink or null)
    else if builtins.isString entry then
      entry
    else
      null;

  declaredSelects =
    let
      raw = nodeAttrs.selects or [ ];
    in
    if builtins.isList raw then raw else [ ];

  resolvedReachability = {
    scope = nodeName;
    offers = offersOf nodeName;
    # Declared order is preserved: precedence stays the model's decision.
    selects = builtins.concatMap (
      entry:
      let
        scope = selectedScopeOf entry;
      in
      if scope == null then
        [ ]
      else
        [
          {
            inherit scope;
            # The member uplinks the selection resolves to. A scope owns its
            # declared uplinks; a scope that names a single uplink owns that
            # uplink. Empty only when the scope is neither, and then the
            # selection restates itself instead of resolving, which the contract
            # forbids -- so it is reported, not defaulted.
            uplinks = uplinksOfNode scope;
            offeredPrefixes = offersOf scope;
            behaviors =
              if builtins.isAttrs entry && builtins.isList (entry.behaviors or null) then
                entry.behaviors
              else
                [ ];
          }
        ]
    ) declaredSelects;
  };
in
{
        logicalNode = logical;
        role = nodeAttrs.role or null;
        # FS-470: explicit node advertisement of, or answering for, a tenant or
        # protected prefix. The compiler resolves the intent declaration to
        # concrete prefixes; the control-plane model consumes them as-is and
        # never re-infers reachability from the NAT source set.
        advertises = if builtins.isList (nodeAttrs.advertises or null) then nodeAttrs.advertises else [ ];
        routingMode = if isBgpRouter then "bgp" else "static";
        placement = placement;
        effectiveRuntimeRealization = {
          loopback = {
            addr4 = requireString "${nodePath}.loopback.ipv4" (loopback.ipv4 or null);
            addr6 = requireString "${nodePath}.loopback.ipv6" (loopback.ipv6 or null);
          };
          interfaces = effectiveRuntimeInterfaces;
          # FS-322-HDS-010-SDS-010-SMS-020: per-scope resolved reachability. A
          # scope's reachability is what it offers plus what it selects, joined
          # here from the compiler's normalized offers/selects. It is never
          # derived from permission relations: URS states reachability and
          # permission "shall not be conflated". Renderers consume this instead
          # of inferring a return leg from a relation record.
          resolvedReachability = resolvedReachability;
        };
      }
      // (
        if isBgpRouter then
          {
            bgp = {
              asn = bgpSiteAsn;
              neighbors =
                (bgpNeighborsForNode nodeName) ++ (ebgpNeighborsForTarget isBgpRouter effectiveRuntimeInterfaces);
              networks = bgpNetworksForNode nodeRole nodeAttrs effectiveRuntimeInterfaces;
            };
          }
        else
          { }
      )
      // (if runtimeContainers != [ ] then { containers = runtimeContainers; } else { })
      // (
        if builtins.isAttrs (nodeAttrs.egressIntent or null) then
          { egressIntent = nodeAttrs.egressIntent; }
        else
          { }
      )
      // (
        if runtimeOriginEgressContract != null then
          { runtimeOriginEgress = runtimeOriginEgressContract; }
        else
          { }
      )
      // (
        if builtins.isAttrs (nodeAttrs.forwardingResponsibility or null) then
          { forwardingResponsibility = nodeAttrs.forwardingResponsibility; }
        else
          { }
      )
      // (
        if builtins.isAttrs (nodeAttrs.routingAuthority or null) then
          { routingAuthority = nodeAttrs.routingAuthority; }
        else
          { }
      )
      // (
        if builtins.isAttrs (nodeAttrs.traversalParticipation or null) then
          { traversalParticipation = nodeAttrs.traversalParticipation; }
        else
          { }
      )
      // (
        if builtins.isList (nodeAttrs.forwardingFunctions or null) then
          { forwardingFunctions = nodeAttrs.forwardingFunctions; }
        else
          { }
      )
      // (
        if builtins.isList (nodeAttrs.attachments or null) then
          { attachments = nodeAttrs.attachments; }
        else
          { }
      )
      // (
        if builtins.isList (nodeAttrs.containers or null) then
          { declaredContainers = nodeAttrs.containers; }
        else
          { }
      )
      // (
        if builtins.isAttrs (nodeAttrs.networks or null) then { networks = nodeAttrs.networks; } else { }
      )
      // (if hasRuntimeServices then { services = runtimeServices; } else { })
      // (if runtimeStatePolicy != { } then { statePolicy = runtimeStatePolicy; } else { })
      // (if runtimeDiagnostics != { } then { diagnostics = runtimeDiagnostics; } else { })
