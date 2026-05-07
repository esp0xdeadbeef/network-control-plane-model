{
  helpers,
  common,
  siteOverlayNameSet,
}:

let
  inherit (helpers) sortedNames;
  inherit (common) attrsOrEmpty defaultDst listContains listOrEmpty;

  isOverlayInterface =
    iface:
    let backingRef = attrsOrEmpty (iface.backingRef or null);
    in (iface.sourceKind or null) == "overlay" || (backingRef.kind or null) == "overlay";

  isOverlayUplinkInterface =
    iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      uplinks = listOrEmpty (backingRef.uplinks or null);
    in
    builtins.any (uplinkName: listContains uplinkName (sortedNames siteOverlayNameSet)) uplinks;

  isDelegatedOverlayIngressInterface =
    sourceNode: iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (backingRef.lane or null);
      uplinks = listOrEmpty (lane.uplinks or null);
      uplink = lane.uplink or null;
      laneUplinks = if uplinks != [ ] then uplinks else if uplink == null then [ ] else [ uplink ];
    in
    (lane.kind or null) == "access-uplink"
    && (lane.access or null) == sourceNode
    && builtins.any (uplinkName: listContains uplinkName (sortedNames siteOverlayNameSet)) laneUplinks;

  egressInterfaceNames =
    targetRole: interfaces:
    builtins.filter
      (ifName:
        let iface = interfaces.${ifName};
        in isOverlayInterface iface || (targetRole != "core" && isOverlayUplinkInterface iface))
      (sortedNames interfaces);

  ingressInterfaceNames =
    sourceNode: interfaces:
    builtins.filter
      (ifName: isDelegatedOverlayIngressInterface sourceNode interfaces.${ifName})
      (sortedNames interfaces);

  delegatedRouteExists =
    family: sourceNode: routes:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.dst or null) == defaultDst family
        && ((attrsOrEmpty (route.intent or null)).kind or null) == "delegated-public-egress"
        && ((attrsOrEmpty (route.intent or null)).exitNode or null) == sourceNode)
      (listOrEmpty routes);

  firstGateway =
    family: routes:
    let
      field = if family == 4 then "via4" else "via6";
      candidates = builtins.filter (route: route.${field} or null != null) routes;
    in
    if candidates == [ ] then null else (builtins.head candidates).${field};

  gatewayForInterface =
    family: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      existingRoutes = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
    in
    firstGateway family existingRoutes;

  firstOverlayGateway =
    family: targetRole: interfaces:
    let
      candidates =
        builtins.filter
          (gateway: gateway != null)
          (builtins.map (ifName: gatewayForInterface family interfaces.${ifName}) (egressInterfaceNames targetRole interfaces));
    in
    if candidates == [ ] then null else builtins.head candidates;

  delegatedOverlayRoute =
    family: sourceNode: metric: gatewayOverride: iface: existingRoutes:
    let
      gateway = if gatewayOverride != null then gatewayOverride else firstGateway family existingRoutes;
      base = {
        dst = defaultDst family;
        intent = {
          kind = "delegated-public-egress";
          source = "external-validation";
          exitNode = sourceNode;
        };
        metric = metric;
        policyOnly = true;
        proto = "overlay";
      };
    in
    if isOverlayInterface iface then
      base // { scope = "link"; }
    else if gateway == null then
      base // { scope = "link"; }
    else
      base // (if family == 4 then { via4 = gateway; } else { via6 = gateway; });

  addToInterface =
    family: sourceNode: metric: gatewayOverride: requireGateway: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      existingRoutes = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
    in
    if delegatedRouteExists family sourceNode existingRoutes || (requireGateway && gatewayOverride == null) then
      iface
    else
      iface
      // {
        routes =
          routes
          // (
            if family == 4 then
              { ipv4 = existingRoutes ++ [ (delegatedOverlayRoute family sourceNode metric gatewayOverride iface existingRoutes) ]; }
            else
              { ipv6 = existingRoutes ++ [ (delegatedOverlayRoute family sourceNode metric gatewayOverride iface existingRoutes) ]; }
          );
      };
in
{
  add =
    {
      family,
      sourceNode,
      metric,
      targetRole,
      interfaces,
    }:
    let
      withEgress =
        builtins.foldl'
          (acc: ifName: acc // { ${ifName} = addToInterface family sourceNode metric null false acc.${ifName}; })
          interfaces
          (egressInterfaceNames targetRole interfaces);
      overlayGateway = firstOverlayGateway family targetRole withEgress;
    in
    builtins.foldl'
      (acc: ifName: acc // { ${ifName} = addToInterface family sourceNode metric overlayGateway true acc.${ifName}; })
      withEgress
      (ingressInterfaceNames sourceNode withEgress);
}
