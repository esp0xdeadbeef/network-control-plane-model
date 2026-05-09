{
  helpers,
  common,
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

  firstGateway =
    family: routes:
    let
      field = if family == 4 then "via4" else "via6";
      candidates = builtins.filter (route: route.${field} or null != null) routes;
    in
    if candidates == [ ] then null else (builtins.head candidates).${field};

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
              in
              firstGateway family (if family == 4 then routes.ipv4 or [ ] else routes.ipv6 or [ ]))
            (builtins.filter (ifName: isOverlayPolicyLane sourceNode interfaces.${ifName}) (sortedNames interfaces)));
    in
    if candidates == [ ] then null else builtins.head candidates;

  routeExists = family: sourceNode: routes:
    builtins.any
      (route:
        (route.dst or null) == defaultDst family
        && ((attrsOrEmpty (route.intent or null)).kind or null) == "delegated-public-egress"
        && ((attrsOrEmpty (route.intent or null)).exitNode or null) == sourceNode)
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
    if routeExists family sourceNode existing then
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
      gateway = policyLaneGateway family sourceNode interfaces;
    in
    if gateway == null then
      interfaces
    else
      builtins.foldl'
        (acc: ifName: acc // { ${ifName} = addRoute family sourceNode gateway acc.${ifName}; })
        interfaces
        (builtins.filter (ifName: isOverlayCoreIngress interfaces.${ifName}) (sortedNames interfaces));
}
