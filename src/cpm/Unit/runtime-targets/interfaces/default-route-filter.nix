{ helpers, common, uplinkRouting }:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty;

  defaultDst = family: if family == 4 then "0.0.0.0/0" else "::/0";
  familyField = family: if family == 4 then "ipv4" else "ipv6";
  bgpPeerField = family: if family == 4 then "peerAddr4" else "peerAddr6";
  routeDst = route: route.prefix or route.dst or null;

  routeIsDefaultReachability = family: route:
    (routeDst route) == defaultDst family
    && ((route.intent or { }).kind or null) == "default-reachability";

  uplinkFamilyConstrained = family:
    let
      field = familyField family;
      peerField = bgpPeerField family;
    in
    builtins.any
      (uplinkName:
        let
          uplinkCfg = attrsOrEmpty (uplinkRouting.${uplinkName} or null);
          staticRoutes = attrsOrEmpty ((attrsOrEmpty (uplinkCfg.static or null)).routes or null);
        in
        (uplinkCfg.mode or null) == "bgp"
        || builtins.hasAttr field staticRoutes
        || isNonEmptyString ((attrsOrEmpty (uplinkCfg.bgp or null)).${peerField} or null))
      (builtins.attrNames uplinkRouting);

  uplinkFamilyDefaultAvailable = family:
    let
      field = familyField family;
      peerField = bgpPeerField family;
    in
    builtins.any
      (uplinkName:
        let
          uplinkCfg = attrsOrEmpty (uplinkRouting.${uplinkName} or null);
          staticRoutes = attrsOrEmpty ((attrsOrEmpty (uplinkCfg.static or null)).routes or null);
          routes = listOrEmpty (staticRoutes.${field} or null);
        in
        (
          (uplinkCfg.mode or null) == "bgp"
          && isNonEmptyString ((attrsOrEmpty (uplinkCfg.bgp or null)).${peerField} or null)
        )
        || builtins.any (route: routeDst route == defaultDst family) routes)
      (builtins.attrNames uplinkRouting);
in
{
  filterUnavailableDefaultRoutes = family: routes:
    if uplinkFamilyConstrained family && !(uplinkFamilyDefaultAvailable family) then
      builtins.filter (route: !(routeIsDefaultReachability family route)) (listOrEmpty routes)
    else
      listOrEmpty routes;
}
