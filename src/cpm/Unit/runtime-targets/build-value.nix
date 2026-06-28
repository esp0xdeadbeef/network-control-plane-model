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
{
        logicalNode = logical;
        role = nodeAttrs.role or null;
        routingMode = if isBgpRouter then "bgp" else "static";
        placement = placement;
        effectiveRuntimeRealization = {
          loopback = {
            addr4 = requireString "${nodePath}.loopback.ipv4" (loopback.ipv4 or null);
            addr6 = requireString "${nodePath}.loopback.ipv6" (loopback.ipv6 or null);
          };
          interfaces = effectiveRuntimeInterfaces;
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
