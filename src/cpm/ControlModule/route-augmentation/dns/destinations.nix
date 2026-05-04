{
  lib,
  common,
  ipam,
  routeHelpers,
}:

let
  inherit (common) listOrEmpty;
  inherit (routeHelpers) routeWithExactDstPresent;
  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);

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

  parseAddress =
    family: address:
    if family == 4 then ipam.parseIPv4 address else ipam.parseIPv6 address;

  addressToInt =
    family: parsed:
    if family == 4 then ipam.ipv4ToInt parsed else ipam.ipv6ToInt parsed;

  networkBaseInt =
    family: attrs:
    if family == 4 then ipam.ipv4NetworkBaseInt attrs else ipam.ipv6NetworkBaseInt attrs;

  ipv6PrefixMatches =
    prefixLen: routeHextets: destinationHextets:
    let
      fullHextets = builtins.div prefixLen 16;
      partialBits = prefixLen - (fullHextets * 16);
      fullMatches =
        builtins.all
          (idx: builtins.elemAt routeHextets idx == builtins.elemAt destinationHextets idx)
          (builtins.genList (idx: idx) fullHextets);
      partialMatches =
        if partialBits == 0 then
          true
        else
          let
            block = pow2 (16 - partialBits);
            routePart = builtins.elemAt routeHextets fullHextets;
            destinationPart = builtins.elemAt destinationHextets fullHextets;
          in
          builtins.div routePart block == builtins.div destinationPart block;
    in
    fullMatches && partialMatches;

  ipv4PrefixMatches =
    prefixLen: routeOctets: destinationOctets:
    networkBaseInt 4 {
      addrInt = addressToInt 4 routeOctets;
      inherit prefixLen;
    } == networkBaseInt 4 {
      addrInt = addressToInt 4 destinationOctets;
      inherit prefixLen;
    };

  routeCoversDestination =
    family: route: destination:
    let
      routeCidr = ipam.splitCIDR (route.dst or null);
      destinationCidr = ipam.splitCIDR destination;
      destinationAddress =
        if destinationCidr == null then
          destination
        else
          destinationCidr.addr;
      routeParsed = if routeCidr == null then null else parseAddress family routeCidr.addr;
      destinationParsed = parseAddress family destinationAddress;
    in
    routeCidr != null
    && routeCidr.prefixLen > 0
    && routeParsed != null
    && destinationParsed != null
    && (
      if family == 4 then
        ipv4PrefixMatches routeCidr.prefixLen routeParsed destinationParsed
      else
        ipv6PrefixMatches routeCidr.prefixLen routeParsed destinationParsed
    );

  routeForCoveringDst =
    { family, routes, destination }:
    lib.findFirst
      (route: builtins.isAttrs route && routeCoversDestination family route destination)
      null
      (listOrEmpty routes);
in
{
  inherit
    routeForCoveringDst
    routeForCanonicalDstWithGateway
    routePresent
    routeWithCanonicalDstPresent
    ;
}
