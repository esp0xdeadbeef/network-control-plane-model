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
  contracts = import ./contracts.nix {
    inherit
      helpers
      common
      routeHelpers
      target
      routeForCoveringDst
      routeForCanonicalDstWithGateway
      routePresent
      ;
  };
in
family: iface: existingRoutes:
contracts.routesForInterface family iface existingRoutes
