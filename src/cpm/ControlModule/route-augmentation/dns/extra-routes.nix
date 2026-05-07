{
  helpers,
  common,
  findSourceRouteForDestination,
  routePresent,
}:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty;
in
family: ifName: existingRoutes: targetExistingRoutes: matchingSpecs:
builtins.foldl'
  (acc: spec:
    let
      preferredUplinks = listOrEmpty (spec.preferredUplinks or null);
      providerPrefixes = if family == 4 then spec.providerPrefixes4 else spec.providerPrefixes6;
      providerAddresses = if family == 4 then spec.providerAddresses4 or [ ] else spec.providerAddresses6 or [ ];
      ingressServiceRoute = listOrEmpty (spec.ingressPreferredUplinks or null) != [ ];
      serviceDestinations = providerPrefixes ++ providerAddresses;
      providerPrefixCovered =
        accumulatedRoutes:
        builtins.any
          (prefix: routePresent family (targetExistingRoutes ++ existingRoutes ++ accumulatedRoutes) prefix)
          providerPrefixes;
    in
    builtins.foldl'
      (inner: destination:
        let
          isProviderAddress = builtins.elem destination providerAddresses;
          sourceRoute = findSourceRouteForDestination family ifName preferredUplinks ingressServiceRoute destination;
          gateway = if sourceRoute == null then null else if family == 4 then sourceRoute.via4 or null else sourceRoute.via6 or null;
          extraRoute =
            if sourceRoute == null || !isNonEmptyString gateway || providerPrefixCovered inner then
              null
            else
              sourceRoute
              // {
                dst = destination;
                intent =
                  (attrsOrEmpty (sourceRoute.intent or null))
                  // {
                    service = spec.serviceName;
                    source = "dns-service";
                  };
              };
        in
        if extraRoute == null || routePresent family (existingRoutes ++ inner) destination then
          inner
        else
          inner ++ [ extraRoute ])
      acc
      serviceDestinations)
  [ ]
  matchingSpecs
