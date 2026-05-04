{
  lib,
  common,
  ipam,
  routeHelpers,
}:

let
  inherit (common) listOrEmpty;
  inherit (routeHelpers) routeWithExactDstPresent;

  canonicalDestination =
    destination:
    let
      cidr = ipam.splitCIDR destination;
    in
    if cidr == null then
      destination
    else
      let
        parsed6 = ipam.parseIPv6 cidr.addr;
        parsed4 = ipam.parseIPv4 cidr.addr;
      in
      if parsed6 != null then
        "${ipam.renderIPv6 parsed6}/${toString cidr.prefixLen}"
      else if parsed4 != null then
        "${ipam.renderIPv4 parsed4}/${toString cidr.prefixLen}"
      else
        destination;

  routeWithCanonicalDstPresent =
    routes: destination:
    let
      expected = canonicalDestination destination;
    in
    builtins.any (
      route: builtins.isAttrs route && canonicalDestination (route.dst or null) == expected
    ) (listOrEmpty routes);

  routePresent =
    family: routes: destination:
    if family == 6 then
      routeWithCanonicalDstPresent routes destination
    else
      routeWithExactDstPresent routes destination;

  routeForCanonicalDstWithGateway =
    { family, routes, destination, isNonEmptyString }:
    let
      expected = canonicalDestination destination;
    in
    lib.findFirst
      (
        route:
        builtins.isAttrs route
        && canonicalDestination (route.dst or null) == expected
        && (if family == 4 then isNonEmptyString (route.via4 or null) else isNonEmptyString (route.via6 or null))
      )
      null
      (listOrEmpty routes);
in
{
  inherit
    routeForCanonicalDstWithGateway
    routePresent
    routeWithCanonicalDstPresent
    ;
}
