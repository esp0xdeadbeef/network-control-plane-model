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
  routeForCanonicalDstWithGateway,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs;
  inherit (common) attrsOrEmpty listOrEmpty;
  inherit (routeHelpers) routeForExactDstWithGateway;
  p2pPeers = import ../p2p-peers.nix { inherit lib; };
in
family: consumerInterfaceName: preferredUplinks: destination:
let
  consumerInterface = interfaces.${consumerInterfaceName};
  includeConsumerInterface =
    isUpstreamSelectorTarget && preferredUplinks != [ ] && laneMatchesPreferredUplinks consumerInterface preferredUplinks;
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
      peer = p2pPeers.peerForInterface family interfaces.${ifName};
    in
    if exact != null then
      exact
    else if includeConsumerInterface && ifName == consumerInterfaceName && isNonEmptyString peer then
      { dst = destination; proto = "default"; }
      // (if family == 4 then { via4 = peer; } else { via6 = peer; })
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
