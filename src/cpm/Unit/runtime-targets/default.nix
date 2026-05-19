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
  overlayProvisioning,
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
  inherit (common) attrsOrEmpty failInventory ipam listOrEmpty mergeRoutes;

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

  overlayUnderlayEndpoints =
    let
      keyed =
        builtins.listToAttrs (
          builtins.map
            (endpoint: {
              name = "${toString (endpoint.family or "")}|${endpoint.sourceFile or ""}";
              value = endpoint;
            })
            (
              builtins.filter
                (endpoint: builtins.isAttrs endpoint && isNonEmptyString (endpoint.sourceFile or null))
                (lib.concatLists (
                  builtins.map
                    (overlayName:
                      builtins.map
                        (endpoint: endpoint // { overlay = overlayName; })
                        (builtins.filter builtins.isAttrs (listOrEmpty (overlayProvisioning.${overlayName}.underlayEndpoints or null))))
                    (sortedNames overlayProvisioning)
                ))
            )
        );
    in
    builtins.map (key: keyed.${key}) (sortedNames keyed);

  defaultViaRoutes =
    family: routes:
    builtins.filter
      (route:
        ((route.intent or { }).kind or null) == "default-reachability"
        && (route.${if family == 4 then "via4" else "via6"} or null) != null)
      (listOrEmpty (routes.${if family == 4 then "ipv4" else "ipv6"} or null));

  underlayEndpointRoutes =
    family: routes:
    let
      viaField = if family == 4 then "via4" else "via6";
      defaults = defaultViaRoutes family routes;
      endpoints = builtins.filter (endpoint: (endpoint.family or null) == family && isNonEmptyString (endpoint.sourceFile or null)) overlayUnderlayEndpoints;
    in
    lib.concatMap
      (defaultRoute:
        builtins.map
          (endpoint: {
            family = family;
            sourceFile = endpoint.sourceFile;
            proto = "underlay";
            overlay = endpoint.overlay;
            intent = {
              kind = "overlay-underlay-reachability";
              source = "overlay-underlay-endpoint";
            };
            ${viaField} = defaultRoute.${viaField};
          })
          endpoints)
      defaults;

  p2pPeerAddress =
    family: cidr:
    let
      parsed = if builtins.isString cidr then ipam.splitCIDR cidr else null;
      expectedPrefixLen = if family == 4 then 31 else 127;
      parsedAddress =
        if parsed == null || parsed.prefixLen != expectedPrefixLen then
          null
        else if family == 4 then
          ipam.parseIPv4 parsed.addr
        else
          ipam.parseIPv6 parsed.addr;
      ipv4PeerInt =
        if parsedAddress == null || family != 4 then
          null
        else
          let addrInt = ipam.ipv4ToInt parsedAddress;
          in if lib.mod addrInt 2 == 0 then addrInt + 1 else addrInt - 1;
      ipv6Peer =
        if parsedAddress == null || family != 6 then
          null
        else
          let
            lastIdx = 7;
            last = builtins.elemAt parsedAddress lastIdx;
            peerLast = if lib.mod last 2 == 0 then last + 1 else last - 1;
          in
          builtins.genList (idx: if idx == lastIdx then peerLast else builtins.elemAt parsedAddress idx) 8;
    in
    if parsedAddress == null then
      null
    else if family == 4 then
      ipam.renderIPv4 (ipam.ipv4FromInt ipv4PeerInt)
    else
      ipam.renderIPv6 ipv6Peer;

  interfaceOverlayLaneNames =
    iface:
    let
      lane = ((iface.backingRef or { }).lane or { });
      uplinks = listOrEmpty (lane.uplinks or null);
      single = lane.uplink or null;
    in
    if (lane.kind or null) != "uplink" then
      [ ]
    else
      uplinks ++ (if isNonEmptyString single then [ single ] else [ ]);

  interfaceOverlayNames =
    interfaces:
    builtins.filter
      (overlayName: hasAttr overlayName overlayProvisioning)
      (
        lib.unique (
          lib.concatMap
            (ifName:
              let
                iface = interfaces.${ifName};
              in
              if (iface.sourceKind or null) == "overlay" then
                [ ((iface.backingRef or { }).name or null) ]
              else
                [ ])
            (sortedNames interfaces)
        )
      );

  overlayEndpointRoutesVia =
    family: overlayNamesForInterface: via:
    let
      viaField = if family == 4 then "via4" else "via6";
      endpoints =
        builtins.filter
          (endpoint:
            (endpoint.family or null) == family
            && isNonEmptyString (endpoint.sourceFile or null)
            && builtins.elem (endpoint.overlay or null) overlayNamesForInterface)
          overlayUnderlayEndpoints;
    in
    if !isNonEmptyString via then
      [ ]
    else
      builtins.map
        (endpoint: {
          family = family;
          sourceFile = endpoint.sourceFile;
          proto = "underlay";
          overlay = endpoint.overlay;
          intent = {
            kind = "overlay-underlay-reachability";
            source = "overlay-underlay-endpoint";
          };
          ${viaField} = via;
        })
        endpoints;

  overlayNodeRoutesVia =
    family: overlayNamesForInterface: via:
    let
      viaField = if family == 4 then "via4" else "via6";
      prefixField = if family == 4 then "ipv4" else "ipv6";
      prefixes =
        lib.unique (
          lib.concatMap
            (overlayName: listOrEmpty (overlayProvisioning.${overlayName}.nodeRoutePrefixes.${prefixField} or null))
            overlayNamesForInterface
        );
    in
    if !isNonEmptyString via then
      [ ]
    else
      builtins.map
        (dst: {
          inherit dst family;
          proto = "internal";
          intent = {
            kind = "overlay-node-reachability";
          };
          ${viaField} = via;
        })
        prefixes;

  overlayRuntimeRoutedPrefixRoutesVia =
    overlayNamesForInterface: via:
    let
      prefixes =
        lib.unique (
          lib.concatMap
            (overlayName: listOrEmpty (overlayProvisioning.${overlayName}.peerRuntimeRoutedPrefixes or null))
            overlayNamesForInterface
        );
    in
    if !isNonEmptyString via then
      [ ]
    else
      builtins.map
        (prefix:
          prefix
          // {
            proto = "overlay";
            intent = {
              kind = "runtime-routed-prefix-return";
              source = "intent-routed-prefix";
            };
            via6 = via;
          })
        prefixes;

  addOverlayNodeRoutesToSelector =
    nodeRole: interfaces:
    if !(nodeRole == "policy" || nodeRole == "upstream-selector") then
      interfaces
    else
      lib.mapAttrs
        (_ifName: iface:
          let
            laneOverlayNames =
              builtins.filter
                (name: builtins.elem name (sortedNames overlayProvisioning))
                (interfaceOverlayLaneNames iface);
            routes = attrsOrEmpty (iface.routes or null);
            extraRoutes = {
              ipv4 = overlayNodeRoutesVia 4 laneOverlayNames (p2pPeerAddress 4 (iface.addr4 or null));
              ipv6 =
                (overlayNodeRoutesVia 6 laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null)))
                ++ (overlayRuntimeRoutedPrefixRoutesVia laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null)));
            };
          in
          if (iface.sourceKind or null) != "p2p" || laneOverlayNames == [ ] || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ]) then
            iface
          else
            iface // { routes = mergeRoutes routes extraRoutes; })
        interfaces;

  addOverlayUnderlayEndpointRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" || overlayUnderlayEndpoints == [ ] then
      interfaces
    else
      let
        nodeOverlayNames = interfaceOverlayNames interfaces;
      in
      if nodeOverlayNames == [ ] then
        interfaces
      else
        lib.mapAttrs
          (_ifName: iface:
            let
              laneOverlayNames = builtins.filter (name: builtins.elem name nodeOverlayNames) (interfaceOverlayLaneNames iface);
              routes = attrsOrEmpty (iface.routes or null);
              extraRoutes = {
                ipv4 = overlayEndpointRoutesVia 4 laneOverlayNames (p2pPeerAddress 4 (iface.addr4 or null));
                ipv6 = overlayEndpointRoutesVia 6 laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null));
              };
            in
            if (iface.sourceKind or null) != "p2p" || laneOverlayNames == [ ] || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ]) then
              iface
            else
              iface // { routes = mergeRoutes routes extraRoutes; })
          interfaces;

  addOverlayUnderlayEndpointRoutes =
    nodeRole: interfaces:
    let
      selectorInterfaces = addOverlayNodeRoutesToSelector nodeRole interfaces;
      coreInterfaces = addOverlayUnderlayEndpointRoutesToCore nodeRole selectorInterfaces;
    in
    if nodeRole != "upstream-selector" || overlayUnderlayEndpoints == [ ] then
      coreInterfaces
    else
      lib.mapAttrs
        (_ifName: iface:
          let
            routes = attrsOrEmpty (iface.routes or null);
            extraRoutes = {
              ipv4 = underlayEndpointRoutes 4 routes;
              ipv6 = underlayEndpointRoutes 6 routes;
            };
          in
          if extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ] then
            iface
          else
            iface // { routes = mergeRoutes routes extraRoutes; })
        coreInterfaces;

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
      runtimeInterfaces = addOverlayUnderlayEndpointRoutes nodeRole (builtins.listToAttrs (explicitEntries ++ syntheticEntries));
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
                networks = bgpNetworksForNode nodeRole nodeAttrs effectiveRuntimeInterfaces;
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
