{ attrsOrEmpty, defaultDst }:

let
  attrValue = value:
    if builtins.isAttrs value then value else { };

  stringOrNull = value:
    if builtins.isString value then value else null;

  boolOrNull = value:
    if builtins.isBool value then value else null;

  reverseList =
    values:
    builtins.foldl' (acc: value: [ value ] ++ acc) [ ] values;

  routeKey =
    family: route:
    if !builtins.isAttrs route then
      null
    else
      let
        intent = attrValue (route.intent or null);
        lane = attrValue (route.lane or null);
      in
      builtins.toJSON [
        family
        (stringOrNull (route.dst or null))
        (stringOrNull (intent.kind or null))
        (stringOrNull (intent.source or null))
        (stringOrNull (lane.access or null))
        (stringOrNull (lane.uplink or null))
        (boolOrNull (route.policyOnly or null))
        (stringOrNull (route.sourceFile or null))
        (stringOrNull (route.via4 or null))
        (stringOrNull (route.via6 or null))
        (stringOrNull (route.scope or null))
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
    && ((attrValue (route.lane or null)).access or "") != "";
in
{
  inherit routeKey uniqueRoutes isPolicyDefault;
}
