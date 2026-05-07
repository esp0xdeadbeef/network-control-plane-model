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

  egressInterfaceNames =
    targetRole: interfaces:
    builtins.filter
      (ifName:
        let iface = interfaces.${ifName};
        in isOverlayInterface iface || (targetRole != "core" && isOverlayUplinkInterface iface))
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

  delegatedOverlayRoute =
    family: sourceNode: metric: iface: existingRoutes:
    let
      gateway = firstGateway family existingRoutes;
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
    family: sourceNode: metric: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      existingRoutes = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
    in
    if delegatedRouteExists family sourceNode existingRoutes then
      iface
    else
      iface
      // {
        routes =
          routes
          // (
            if family == 4 then
              { ipv4 = existingRoutes ++ [ (delegatedOverlayRoute family sourceNode metric iface existingRoutes) ]; }
            else
              { ipv6 = existingRoutes ++ [ (delegatedOverlayRoute family sourceNode metric iface existingRoutes) ]; }
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
    builtins.foldl'
      (acc: ifName: acc // { ${ifName} = addToInterface family sourceNode metric acc.${ifName}; })
      interfaces
      (egressInterfaceNames targetRole interfaces);
}
