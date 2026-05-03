{ helpers, failInventory }:

let
  inherit (helpers) requireAttrs requireString;

  normalizeRoute = family: routePath: routeValue:
    let
      route =
        if builtins.isAttrs routeValue then
          routeValue
        else
          failInventory routePath "must be an attribute set";

      dst = requireString "${routePath}.prefix" (route.prefix or null);
      via = requireString "${routePath}.via" (route.via or null);
    in
    {
      inherit dst;
      intent = {
        kind = "realized-interface-route";
        source = "inventory-realization";
      };
      proto = "realized";
      ${if family == 4 then "via4" else "via6"} = via;
    }
    // (
      if builtins.isInt (route.metric or null) then
        { metric = route.metric; }
      else
        { }
    );

  requireRouteList = routePath: routeValue:
    if builtins.isList routeValue then
      routeValue
    else
      failInventory routePath "must be a list";

  requireRoutes = path: value:
    let
      routes =
        if builtins.isAttrs value then
          value
        else
          failInventory path "must be an attrset with routes.ipv4/routes.ipv6 lists";
    in
    {
      ipv4 =
        builtins.map
          (route: normalizeRoute 4 "${path}.ipv4[]" route)
          (requireRouteList "${path}.ipv4" (routes.ipv4 or [ ]));
      ipv6 =
        builtins.map
          (route: normalizeRoute 6 "${path}.ipv6[]" route)
          (requireRouteList "${path}.ipv6" (routes.ipv6 or [ ]));
    };

in
{
  inherit requireRoutes;
}
