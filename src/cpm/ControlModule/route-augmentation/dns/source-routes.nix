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
}:

let
  inherit (helpers) isNonEmptyString requireAttrs;
  inherit (common) attrsOrEmpty listOrEmpty;
  inherit (routeHelpers) routeForExactDstWithGateway;
in
family: consumerInterfaceName: preferredUplinks: ingressServiceRoute: destination:
let
  consumerInterface = interfaces.${consumerInterfaceName};
  includeConsumerInterface =
    preferredUplinks != [ ]
    && !ingressServiceRoute
    && laneMatchesPreferredUplinks consumerInterface preferredUplinks;
  candidateInterfaceNames =
    (lib.optional includeConsumerInterface consumerInterfaceName)
    ++ builtins.filter
      (
        ifName:
        ifName != consumerInterfaceName
        && lanePreservesConsumerPath preferredUplinks consumerInterface interfaces.${ifName}
        && laneMatchesPreferredUplinks interfaces.${ifName} preferredUplinks
      )
      interfaceNames;
  defaultDst = if family == 4 then "0.0.0.0/0" else "::/0";
  routeForDestinationOrDefault =
    ifName: routes:
    let
      exact = routeForCanonicalDstWithGateway {
        inherit family routes destination isNonEmptyString;
      };
      covering = routeForCoveringDst {
        inherit family routes destination;
      };
    in
    if exact != null then
      exact
    else if covering != null && isNonEmptyString (if family == 4 then (covering.via4 or null) else (covering.via6 or null)) then
      covering
    else
      routeForExactDstWithGateway family routes defaultDst;
in
lib.findFirst
  (route: route != null)
  null
  (builtins.map
    (ifName:
      let
        candidateIface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
        candidateRoutes = attrsOrEmpty (candidateIface.routes or null);
        familyRoutes =
          if family == 4 then listOrEmpty (candidateRoutes.ipv4 or null) else listOrEmpty (candidateRoutes.ipv6 or null);
      in
      routeForDestinationOrDefault ifName familyRoutes)
    candidateInterfaceNames)
