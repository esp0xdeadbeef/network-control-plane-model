{ attrsOrEmpty, defaultDst }:

let
  reverseList =
    values:
    builtins.foldl' (acc: value: [ value ] ++ acc) [ ] values;

  routeKey =
    family: route:
    if !builtins.isAttrs route then
      null
    else
      let
        intent = attrsOrEmpty (route.intent or null);
        lane = attrsOrEmpty (route.lane or null);
      in
      builtins.toJSON [
        family
        (route.dst or null)
        (intent.kind or null)
        (intent.source or null)
        (lane.access or null)
        (lane.uplink or null)
        (route.policyOnly or null)
        (route.sourceFile or null)
        (route.via4 or null)
        (route.via6 or null)
        (route.scope or null)
      ];

  uniqueRoutes =
    family: routes:
    if routes == [ ] then
      [ ]
    else if builtins.length routes == 1 then
      let
        route = builtins.elemAt routes 0;
      in
      if routeKey family route == null then [ ] else routes
    else
      let
        result =
          builtins.foldl'
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
                  values = [ route ] ++ acc.values;
                }
            )
            {
              seen = { };
              values = [ ];
            }
            routes;
      in
      reverseList result.values;

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
