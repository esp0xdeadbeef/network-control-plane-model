{ common }:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  routeKey =
    family: route:
    if !builtins.isAttrs route then
      null
    else
      builtins.toJSON {
        inherit family;
        dst = route.dst or null;
        intent = route.intent or null;
        lane = route.lane or null;
        metric = route.metric or null;
        policyOnly = route.policyOnly or null;
        proto = route.proto or null;
        reason = route.reason or null;
        table = route.table or null;
        sourceFile = route.sourceFile or null;
        via4 = route.via4 or null;
        via6 = route.via6 or null;
        scope = route.scope or null;
      };

  uniqueRoutes =
    family: routes:
    (builtins.foldl'
      (acc: route:
        let key = routeKey family route;
        in
        if key == null || builtins.hasAttr key acc.seen then
          acc
        else
          {
            seen = acc.seen // { ${key} = true; };
            values = acc.values ++ [ route ];
          })
      { seen = { }; values = [ ]; }
      routes).values;

  normalizeRuntimeTargetRoutes =
    target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      normalizedInterfaces =
        builtins.mapAttrs
          (_ifName: iface:
            let
              routes = attrsOrEmpty (iface.routes or null);
              ipv4 = listOrEmpty (routes.ipv4 or null);
              ipv6 = listOrEmpty (routes.ipv6 or null);
            in
            if ipv4 == [ ] && ipv6 == [ ] then
              iface
            else
              iface // { routes = routes // { ipv4 = uniqueRoutes 4 ipv4; ipv6 = uniqueRoutes 6 ipv6; }; })
          interfaces;
    in
    if interfaces == { } then target else target // { effectiveRuntimeRealization = effective // { interfaces = normalizedInterfaces; }; };
in
{
  inherit normalizeRuntimeTargetRoutes uniqueRoutes;
}
