{
  helpers,
  common,
  routeHelpers,
  target,
  routeForCoveringDst,
  routeForCanonicalDstWithGateway,
  routePresent,
}:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty;
  inherit (routeHelpers) routeForExactDstWithGateway;

  isFamilyDestination =
    family: destination:
    builtins.isString destination
    && destination != ""
    && (if family == 4 then builtins.match ".*:.*" destination == null else builtins.match ".*:.*" destination != null);

  destinations =
    family:
    let
      dns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
      routeContracts = listOrEmpty (dns.routeContracts or null);
      forwarders = listOrEmpty (dns.forwarders or null);
      rawDestinations =
        builtins.filter
          (destination: isFamilyDestination family destination)
          ((map (contract: (attrsOrEmpty contract).dst or null) routeContracts) ++ forwarders);
    in
    builtins.attrNames (builtins.listToAttrs (map (destination: { name = destination; value = true; }) rawDestinations));

  routeForContract =
    family: existingRoutes: destination:
    let
      exact = routeForCanonicalDstWithGateway {
        inherit family destination isNonEmptyString;
        routes = existingRoutes;
      };
      covering = routeForCoveringDst {
        inherit family destination;
        routes = existingRoutes;
      };
      coveringGateway =
        if covering == null then null else if family == 4 then covering.via4 or null else covering.via6 or null;
      defaultDst = if family == 4 then "0.0.0.0/0" else "::/0";
      fallback = routeForExactDstWithGateway family existingRoutes defaultDst;
      sourceRoute =
        if exact != null then
          exact
        else if covering != null && isNonEmptyString coveringGateway then
          covering
        else
          fallback;
      gateway = if sourceRoute == null then null else if family == 4 then sourceRoute.via4 or null else sourceRoute.via6 or null;
      dst = if family == 4 then "${destination}/32" else "${destination}/128";
    in
    if sourceRoute == null || !isNonEmptyString gateway then
      null
    else
      builtins.removeAttrs sourceRoute [ "dst" ]
      // {
        dst = dst;
        proto = "dns-service";
        intent =
          (attrsOrEmpty (sourceRoute.intent or null))
          // {
            service = "dns";
            source = "dns-service";
          };
      };

in
{
  routesForInterface =
    family: iface: existingRoutes:
    let
      contractDestinations = destinations family;
    in
    if (iface.sourceKind or null) != "p2p" || contractDestinations == [ ] then
      [ ]
    else
      builtins.foldl'
        (acc: destination:
          let route = routeForContract family existingRoutes destination;
          in
          if route == null || routePresent family (existingRoutes ++ acc) destination then
            acc
          else
            acc ++ [ route ])
        [ ]
        contractDestinations;
}
