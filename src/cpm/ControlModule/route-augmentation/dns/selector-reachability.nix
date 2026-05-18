{
  lib,
  helpers,
  common,
  routeHelpers,
  targetPath,
  interfaces,
  interfaceNames,
  isUpstreamSelectorTarget,
  laneMatchesPreferredUplinks,
  lanePreservesConsumerPath,
  routeForCoveringDst,
  routeForCanonicalDstWithGateway,
  routePresent,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  findSourceRouteForDestination = import ./source-routes.nix {
    inherit
      helpers
      lib
      common
      routeHelpers
      targetPath
      interfaces
      interfaceNames
      isUpstreamSelectorTarget
      laneMatchesPreferredUplinks
      lanePreservesConsumerPath
      routeForCoveringDst
      routeForCanonicalDstWithGateway
      ;
  };

  routesWithDnsExtras = import ./extra-routes.nix {
    inherit helpers common interfaces isUpstreamSelectorTarget findSourceRouteForDestination routePresent;
  };

in
{
  matchingSpecsForInterface =
    ifName: existingV4: existingV6: dnsServiceRouteSpecs:
    builtins.filter
      (spec:
        builtins.any (destination: routeHelpers.routeWithExactDstPresent existingV4 destination) spec.consumerPrefixes4
        || builtins.any (destination: routePresent 6 existingV6 destination) spec.consumerPrefixes6
        || (
          let preferredUplinks = listOrEmpty (spec.preferredUplinks or null);
          in preferredUplinks != [ ] && isUpstreamSelectorTarget && laneMatchesPreferredUplinks interfaces.${ifName} preferredUplinks
        )
        || (
          let preferredUplinks = listOrEmpty (spec.ingressPreferredUplinks or null);
          in preferredUplinks != [ ] && isUpstreamSelectorTarget && laneMatchesPreferredUplinks interfaces.${ifName} preferredUplinks
        ))
      dnsServiceRouteSpecs;

  extraRoutes =
    family: ifName: existingRoutes: targetExistingRoutes: matchingSpecs:
    routesWithDnsExtras family ifName existingRoutes targetExistingRoutes matchingSpecs;
}
