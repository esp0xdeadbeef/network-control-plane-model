{
  helpers,
  common,
  ipam,
  siteOverlayNameSet,
}:

let
  inherit (helpers) sortedNames;
  inherit (common) attrsOrEmpty defaultDst listContains listOrEmpty;

  laneFor = iface:
    attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);

  laneUplinks = lane:
    if builtins.isList (lane.uplinks or null) then
      lane.uplinks
    else if lane.uplink or null == null then
      [ ]
    else
      [ lane.uplink ];

  laneUsesOverlay = lane:
    builtins.any (uplinkName: listContains uplinkName (sortedNames siteOverlayNameSet)) (laneUplinks lane);

  isOverlayCoreIngress = iface:
    let lane = laneFor iface;
    in (lane.kind or null) == "uplink" && laneUsesOverlay lane;

  isOverlayPolicyLane = sourceNode: iface:
    let lane = laneFor iface;
    in (lane.kind or null) == "access-uplink" && (lane.access or null) == sourceNode && laneUsesOverlay lane;

  isNonOverlayPolicyLane = sourceNode: iface:
    let lane = laneFor iface;
    in (lane.kind or null) == "access-uplink" && (lane.access or null) == sourceNode && !laneUsesOverlay lane;

  isNonOverlayCoreLane = iface:
    let lane = laneFor iface;
    in (lane.kind or null) == "uplink" && !laneUsesOverlay lane;

  hasDefault = family: routes:
    builtins.any (route: (route.dst or null) == defaultDst family) (listOrEmpty routes);

  hasNonOverlayDefault = family: sourceNode: interfaces:
    builtins.any
      (ifName:
        let
          iface = interfaces.${ifName};
          routes = attrsOrEmpty (iface.routes or null);
        in
        isNonOverlayPolicyLane sourceNode iface
        && hasDefault family (if family == 4 then routes.ipv4 or [ ] else routes.ipv6 or [ ]))
      (sortedNames interfaces);

  isDelegatedPublicEgress = route:
    ((attrsOrEmpty (route.intent or null)).kind or null) == "delegated-public-egress";

  firstGateway =
    family: routes:
    let
      field = if family == 4 then "via4" else "via6";
      candidates = builtins.filter (route: !isDelegatedPublicEgress route && route.${field} or null != null) routes;
    in
    if candidates == [ ] then null else (builtins.head candidates).${field};

  p2pPeerAddress =
    family: iface:
    let
      cidr = ipam.splitCIDR (if family == 4 then iface.addr4 or "" else iface.addr6 or "");
      prefixLen = if cidr == null then null else cidr.prefixLen;
      parsed4 = if cidr == null || family != 4 then null else ipam.parseIPv4 cidr.addr;
      parsed6 = if cidr == null || family != 6 then null else ipam.parseIPv6 cidr.addr;
      addr4Int = if parsed4 == null then null else ipam.ipv4ToInt parsed4;
      peer4 =
        if prefixLen != 31 || addr4Int == null then
          null
        else if (builtins.div addr4Int 2) * 2 == addr4Int then
          ipam.renderIPv4 (addr4Int + 1)
        else
          ipam.renderIPv4 (addr4Int - 1);
      peer6 =
        if prefixLen != 127 || parsed6 == null then
          null
        else
          let
            idx = 7;
            last = builtins.elemAt parsed6 idx;
            peerLast = if (builtins.div last 2) * 2 == last then last + 1 else last - 1;
          in
          ipam.renderIPv6 ((builtins.genList (i: if i == idx then peerLast else builtins.elemAt parsed6 i) 8));
    in
    if family == 4 then peer4 else peer6;

  policyLaneGateway =
    family: sourceNode: interfaces:
    let
      candidates =
        builtins.filter
          (gateway: gateway != null)
          (builtins.map
            (ifName:
              let
                iface = interfaces.${ifName};
                routes = attrsOrEmpty (iface.routes or null);
                peerAddress = p2pPeerAddress family iface;
              in
              if peerAddress != null then peerAddress else firstGateway family (if family == 4 then routes.ipv4 or [ ] else routes.ipv6 or [ ]))
            (builtins.filter (ifName: isOverlayPolicyLane sourceNode interfaces.${ifName}) (sortedNames interfaces)));
    in
    if candidates == [ ] then null else builtins.head candidates;

  nonOverlayCoreGateway =
    family: interfaces:
    let
      candidates =
        builtins.filter
          (gateway: gateway != null)
          (builtins.map
            (ifName:
              let
                iface = interfaces.${ifName};
                routes = attrsOrEmpty (iface.routes or null);
                peerAddress = p2pPeerAddress family iface;
              in
              if peerAddress != null then peerAddress else firstGateway family (if family == 4 then routes.ipv4 or [ ] else routes.ipv6 or [ ]))
            (builtins.filter (ifName: isNonOverlayCoreLane interfaces.${ifName}) (sortedNames interfaces)));
    in
    if candidates == [ ] then null else builtins.head candidates;

  routeGatewayMatches = family: gateway: route:
    if family == 4 then (route.via4 or null) == gateway else (route.via6 or null) == gateway;

  routeExists = family: sourceNode: gateway: routes:
    builtins.any
      (route:
        (route.dst or null) == defaultDst family
        && ((attrsOrEmpty (route.intent or null)).kind or null) == "delegated-public-egress"
        && ((attrsOrEmpty (route.intent or null)).exitNode or null) == sourceNode
        && routeGatewayMatches family gateway route)
      (listOrEmpty routes);

  addRoute = family: sourceNode: gateway: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      existing = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
      route = {
        dst = defaultDst family;
        intent = {
          kind = "delegated-public-egress";
          source = "overlay-exit-site";
          exitNode = sourceNode;
        };
        metric = 50;
        policyOnly = true;
        proto = "overlay";
      } // (if family == 4 then { via4 = gateway; } else { via6 = gateway; });
    in
    if routeExists family sourceNode gateway existing then
      iface
    else
      iface // { routes = routes // (if family == 4 then { ipv4 = existing ++ [ route ]; } else { ipv6 = existing ++ [ route ]; }); };
in
{
  add =
    {
      family,
      sourceNode,
      interfaces,
    }:
    let
      sourceHasNonOverlayDefault = hasNonOverlayDefault family sourceNode interfaces;
      coreGateway = nonOverlayCoreGateway family interfaces;
      gateway =
        if coreGateway != null then
          coreGateway
        else
          policyLaneGateway family sourceNode interfaces;
    in
    if sourceHasNonOverlayDefault || gateway == null then
      interfaces
    else
      builtins.foldl'
        (acc: ifName: acc // { ${ifName} = addRoute family sourceNode gateway acc.${ifName}; })
        interfaces
        (builtins.filter (ifName: isOverlayCoreIngress interfaces.${ifName}) (sortedNames interfaces));
}
