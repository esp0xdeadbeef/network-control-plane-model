{ defaultDst }:

let
  routeKernelKey =
    family: route:
    let
      viaField = if family == 4 then "via4" else "via6";
      lane = if route.policyOnly or false then route.lane or null else null;
    in
    builtins.toJSON {
      inherit family;
      dst = route.dst or null;
      inherit lane;
      policyOnly = route.policyOnly or null;
      proto = route.proto or null;
      scope = route.scope or null;
      table = route.table or null;
      via = route.${viaField} or null;
    };
in
{
  uniqueKernelDefaults =
    family: routes:
    (builtins.foldl'
      (acc: route:
        let
          key = routeKernelKey family route;
          isKernelDefault =
            builtins.isAttrs route
            && (route.dst or null) == defaultDst family
            && ((route.intent or { }).kind or null) == "default-reachability";
        in
        if isKernelDefault && builtins.hasAttr key acc.seen then
          acc
        else
          {
            seen = if isKernelDefault then acc.seen // { ${key} = true; } else acc.seen;
            values = acc.values ++ [ route ];
          })
      { seen = { }; values = [ ]; }
      routes).values;
}
