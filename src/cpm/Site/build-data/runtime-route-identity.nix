{ attrsOrEmpty, defaultDst }:

let
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
      (
        acc: route:
        let
          key = routeKey family route;
        in
        if key == null || builtins.hasAttr key acc.seen then
          acc
        else
          {
            seen = acc.seen // {
              ${key} = true;
            };
            values = acc.values ++ [ route ];
          }
      )
      {
        seen = { };
        values = [ ];
      }
      routes
    ).values;

  isPolicyDefault =
    family: route:
    builtins.isAttrs route
    && (route.policyOnly or false) == true
    && (route.dst or null) == defaultDst family
    && ((attrsOrEmpty (route.lane or null)).access or "") != "";
in
{
  inherit routeKey uniqueRoutes isPolicyDefault;
}
