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
  peerNodeAttrs,
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
