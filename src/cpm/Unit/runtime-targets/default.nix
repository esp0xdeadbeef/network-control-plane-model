{
  lib,
  helpers,
  common,
  realizationIndex,
  enterpriseName,
  siteName,
  sitePath,
  nodes,
  routingMode,
  bgpSiteAsn,
  bgpTopology,
  uplinkRouting,
  buildExplicitInterfaceEntry,
  buildSyntheticUplinkInterfaceEntry,
  resolveRuntimeContainers,
  resolveRuntimeServices,
  bgpNetworksForNode,
  bgpNeighborsForNode,
  filterRoutesForBgp,
  routerRoleSet,
}:

let
  inherit (helpers) hasAttr isNonEmptyString logicalKey requireAttrs requireString sortedNames;
  inherit (common) attrsOrEmpty failInventory;

  defaultPortBindings = {
    byLink = { };
    byLogicalInterface = { };
    byUplink = { };
    portDefs = { };
  };

  hasExplicitWANForUplink =
    nodeInterfaces: uplinkName:
    builtins.any
      (ifName:
        let
          iface = requireAttrs "${sitePath}.nodes[*].interfaces.${ifName}" nodeInterfaces.${ifName};
        in
        (iface.kind or null) == "wan" && (iface.upstream or null) == uplinkName)
      (sortedNames nodeInterfaces);

  validateSiteRouting =
    if routingMode == "bgp" then
      if !builtins.isInt bgpSiteAsn then
        failInventory "inventory.controlPlane.sites.${enterpriseName}.${siteName}.routing.bgp.asn" "bgp mode requires integer 'asn'"
      else if bgpTopology != "policy-rr" then
        failInventory "inventory.controlPlane.sites.${enterpriseName}.${siteName}.routing.bgp.topology" "only 'policy-rr' is supported right now"
      else
        true
    else
      true;

  ebgpNeighborsForTarget =
    isBgpRouter: effectiveRuntimeInterfaces:
    if !isBgpRouter then
      [ ]
    else
      lib.concatMap
        (ifName:
          let
            iface = effectiveRuntimeInterfaces.${ifName};
            upstream = iface.upstream or null;
            uplinkCfg = if isNonEmptyString upstream && hasAttr upstream uplinkRouting then uplinkRouting.${upstream} else null;
            uplinkMode = if uplinkCfg == null then null else uplinkCfg.mode or null;
            uplinkBgp = if uplinkCfg == null then { } else attrsOrEmpty (uplinkCfg.bgp or null);
            peerAddr4 = uplinkBgp.peerAddr4 or null;
            peerAddr6 = uplinkBgp.peerAddr6 or null;
          in
          if (iface.sourceKind or null) != "wan" || uplinkMode != "bgp" then
            [ ]
          else
            [
              ({
                peer_name = "uplink-${upstream}";
                peer_kind = "external-uplink";
                uplink = upstream;
                peer_asn = uplinkBgp.peerAsn or null;
                update_source = iface.runtimeIfName or null;
                route_reflector_client = false;
              }
              // (if isNonEmptyString peerAddr4 then { peer_addr4 = peerAddr4; } else { })
              // (if isNonEmptyString peerAddr6 then { peer_addr6 = peerAddr6; } else { }))
            ])
        (sortedNames effectiveRuntimeInterfaces);

  buildRuntimeTarget =
    nodeName:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath nodes.${nodeName};
      nodeRoleRaw = nodeAttrs.role or null;
      nodeRole = if builtins.isString nodeRoleRaw then nodeRoleRaw else "";
      isBgpRouter = routingMode == "bgp" && isNonEmptyString nodeRole && hasAttr nodeRole routerRoleSet;
      logical = { enterprise = enterpriseName; site = siteName; name = nodeName; };
      logicalId = logicalKey logical;
      realizedTarget = hasAttr logicalId realizationIndex.byLogical;
      targetId = if realizedTarget then realizationIndex.byLogical.${logicalId} else nodeName;
      targetDef = if realizedTarget then realizationIndex.targetDefs.${targetId} else null;
      targetHostName = if realizedTarget then requireString "${targetDef.nodePath}.host" (targetDef.node.host or null) else null;
      targetPlatform = if realizedTarget then requireString "${targetDef.nodePath}.platform" (targetDef.node.platform or null) else null;
      portBindings = if realizedTarget then targetDef.portBindings else defaultPortBindings;
      nodeInterfaces = requireAttrs "${nodePath}.interfaces" (nodeAttrs.interfaces or null);
      explicitEntries =
        builtins.map
          (ifName: buildExplicitInterfaceEntry { inherit nodeName ifName portBindings targetHostName targetId realizedTarget; iface = nodeInterfaces.${ifName}; })
          (sortedNames nodeInterfaces);
      uplinkAttrs = if builtins.isAttrs (nodeAttrs.uplinks or null) then nodeAttrs.uplinks else { };
      syntheticEntries =
        builtins.map
          (uplinkName: buildSyntheticUplinkInterfaceEntry { inherit nodeName uplinkName portBindings targetHostName targetId realizedTarget; uplinkValue = uplinkAttrs.${uplinkName}; })
          (builtins.filter (uplinkName: !hasExplicitWANForUplink nodeInterfaces uplinkName) (sortedNames uplinkAttrs));
      runtimeInterfaces = builtins.listToAttrs (explicitEntries ++ syntheticEntries);
      effectiveRuntimeInterfaces = if isBgpRouter then lib.mapAttrs (_: iface: iface // { routes = filterRoutesForBgp (iface.routes or { }); }) runtimeInterfaces else runtimeInterfaces;
      loopback = requireAttrs "${nodePath}.loopback" (nodeAttrs.loopback or null);
      placement =
        if realizedTarget then
          { kind = "inventory-realization"; target = targetId; host = targetHostName; platform = targetPlatform; }
        else
          { kind = "logical-node"; target = nodeName; };
      runtimeContainers = resolveRuntimeContainers { inherit nodePath nodeName realizedTarget targetId targetDef nodeAttrs; };
      runtimeServices = if realizedTarget && builtins.isAttrs (targetDef.node.services or null) then resolveRuntimeServices { inherit nodePath nodeName nodeAttrs targetDef; } else null;
      value =
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
                neighbors = (bgpNeighborsForNode nodeName) ++ (ebgpNeighborsForTarget isBgpRouter effectiveRuntimeInterfaces);
                networks = bgpNetworksForNode nodeRole effectiveRuntimeInterfaces;
              };
            }
          else
            { }
        )
        // (if runtimeContainers != [ ] then { containers = runtimeContainers; } else { })
        // (if builtins.isAttrs (nodeAttrs.egressIntent or null) then { egressIntent = nodeAttrs.egressIntent; } else { })
        // (if builtins.isAttrs (nodeAttrs.forwardingResponsibility or null) then { forwardingResponsibility = nodeAttrs.forwardingResponsibility; } else { })
        // (if builtins.isAttrs (nodeAttrs.routingAuthority or null) then { routingAuthority = nodeAttrs.routingAuthority; } else { })
        // (if builtins.isAttrs (nodeAttrs.traversalParticipation or null) then { traversalParticipation = nodeAttrs.traversalParticipation; } else { })
        // (if builtins.isList (nodeAttrs.forwardingFunctions or null) then { forwardingFunctions = nodeAttrs.forwardingFunctions; } else { })
        // (if builtins.isList (nodeAttrs.attachments or null) then { attachments = nodeAttrs.attachments; } else { })
        // (if builtins.isList (nodeAttrs.containers or null) then { declaredContainers = nodeAttrs.containers; } else { })
        // (if builtins.isAttrs (nodeAttrs.networks or null) then { networks = nodeAttrs.networks; } else { })
        // (if runtimeServices != null then { services = runtimeServices; } else { });
    in
    { name = targetId; value = value; };
in
{
  runtimeTargets =
    builtins.seq validateSiteRouting (
      builtins.listToAttrs (builtins.map buildRuntimeTarget (sortedNames nodes))
    );
}
