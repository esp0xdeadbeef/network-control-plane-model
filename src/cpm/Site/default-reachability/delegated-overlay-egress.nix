{
  helpers,
  common,
}:

let
  inherit (helpers) sortedNames;
  inherit (common) attrsOrEmpty defaultDst listOrEmpty;

  isOverlayInterface =
    iface:
    let backingRef = attrsOrEmpty (iface.backingRef or null);
    in (iface.sourceKind or null) == "overlay" || (backingRef.kind or null) == "overlay";

  overlayInterfaceNames =
    interfaces: builtins.filter (ifName: isOverlayInterface interfaces.${ifName}) (sortedNames interfaces);

  delegatedRouteExists =
    family: sourceNode: routes:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.dst or null) == defaultDst family
        && ((attrsOrEmpty (route.intent or null)).kind or null) == "delegated-public-egress"
        && ((attrsOrEmpty (route.intent or null)).exitNode or null) == sourceNode)
      (listOrEmpty routes);

  delegatedOverlayRoute =
    family: sourceNode: metric:
    {
      dst = defaultDst family;
      intent = {
        kind = "delegated-public-egress";
        source = "external-validation";
        exitNode = sourceNode;
      };
      metric = metric;
      policyOnly = true;
      proto = "overlay";
      scope = "link";
    };

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
              { ipv4 = existingRoutes ++ [ (delegatedOverlayRoute family sourceNode metric) ]; }
            else
              { ipv6 = existingRoutes ++ [ (delegatedOverlayRoute family sourceNode metric) ]; }
          );
      };
in
{
  add =
    {
      family,
      sourceNode,
      metric,
      interfaces,
    }:
    builtins.foldl'
      (acc: ifName: acc // { ${ifName} = addToInterface family sourceNode metric acc.${ifName}; })
      interfaces
      (overlayInterfaceNames interfaces);
}
