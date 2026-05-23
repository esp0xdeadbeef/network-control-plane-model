{ attrsOrEmpty, defaultDst }:

let
  routeKey =
    family: route:
    if !builtins.isAttrs route then
      null
    else
      let
        intent = attrsOrEmpty (route.intent or null);
        lane = attrsOrEmpty (route.lane or null);
      in
      builtins.toJSON {
        inherit family;
        dst = route.dst or null;
        intent = {
          kind = intent.kind or null;
          source = intent.source or null;
        };
        lane = {
          access = lane.access or null;
          uplink = lane.uplink or null;
        };
        policyOnly = route.policyOnly or null;
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
