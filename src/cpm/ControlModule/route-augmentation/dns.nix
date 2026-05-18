{
  lib,
  helpers,
  common,
  ipam,
  routeHelpers,
  sitePath,
  dnsServiceRouteSpecs,
}:

let
  inherit (helpers) requireAttrs sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;

  laneHelpers = import ../../Site/topology/lane-metadata.nix { inherit helpers; };
  inherit (laneHelpers) interfaceLane laneUplinks;

  destinationHelpers = import ./dns/destinations.nix {
    inherit lib common ipam routeHelpers;
  };
  inherit (destinationHelpers)
    routeForCoveringDst
    routeForCanonicalDstWithGateway
    routePresent
    ;
in
targetName: target:
let
  targetPath = "${sitePath}.runtimeTargets.${targetName}";
  effective =
    requireAttrs
      "${targetPath}.effectiveRuntimeRealization"
      (target.effectiveRuntimeRealization or null);
  interfaces =
    requireAttrs
      "${targetPath}.effectiveRuntimeRealization.interfaces"
      (effective.interfaces or null);
  interfaceNames = sortedNames interfaces;
  hasOverlayInterface =
    lib.any
      (ifName: (attrsOrEmpty ((interfaces.${ifName} or { }).backingRef or null)).kind or null == "overlay")
      interfaceNames;
  terminatesExternalUplink =
    target.role or null == "core"
    && builtins.isAttrs (target.egressIntent or null)
    && (target.egressIntent.exit or false);
  skipDnsServiceRouteAugmentation =
    hasOverlayInterface && terminatesExternalUplink;
  isUpstreamSelectorTarget = target.role or null == "upstream-selector";
  laneMatchesPreferredUplinks =
    iface: preferredUplinks:
    let
      lane = interfaceLane iface;
    in
    preferredUplinks == [ ]
    || builtins.any (uplinkName: builtins.elem uplinkName (laneUplinks lane)) preferredUplinks;

  lanePreservesConsumerPath =
    preferredUplinks: consumerIface: candidateIface:
    let
      consumerLane = interfaceLane consumerIface;
      candidateLane = interfaceLane candidateIface;
      sameAccessUplink =
        (consumerLane.kind or null) == "access"
        && (candidateLane.kind or null) == "access-uplink"
        && (consumerLane.access or null) == (candidateLane.access or null);
    in
    preferredUplinks == [ ]
    || consumerLane == { }
    || candidateLane == { }
    || candidateLane == consumerLane
    || sameAccessUplink
    || (laneMatchesPreferredUplinks consumerIface preferredUplinks && laneMatchesPreferredUplinks candidateIface preferredUplinks);

  accessDnsService = import ./dns/access-service.nix {
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

  selectorReachability = import ./dns/selector-reachability.nix {
    inherit
      lib
      helpers
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
      routePresent
      ;
  };

  updatedInterfaces =
    let
      targetExistingV4 =
        lib.concatMap
          (name: listOrEmpty ((attrsOrEmpty ((interfaces.${name} or { }).routes or null)).ipv4 or null))
          interfaceNames;
      targetExistingV6 =
        lib.concatMap
          (name: listOrEmpty ((attrsOrEmpty ((interfaces.${name} or { }).routes or null)).ipv6 or null))
          interfaceNames;
    in
    builtins.mapAttrs
      (ifName: iface:
        let
          routes = attrsOrEmpty (iface.routes or null);
          existingV4 = listOrEmpty (routes.ipv4 or null);
          existingV6 = listOrEmpty (routes.ipv6 or null);
          matchingSpecs = selectorReachability.matchingSpecsForInterface ifName existingV4 existingV6 dnsServiceRouteSpecs;
          extraV4 = selectorReachability.extraRoutes 4 ifName existingV4 targetExistingV4 matchingSpecs;
          extraV6 = selectorReachability.extraRoutes 6 ifName existingV6 targetExistingV6 matchingSpecs;
          contractV4 = accessDnsService 4 iface (existingV4 ++ extraV4);
          contractV6 = accessDnsService 6 iface (existingV6 ++ extraV6);
        in
        if extraV4 == [ ] && extraV6 == [ ] && contractV4 == [ ] && contractV6 == [ ] then
          iface
        else
          iface
          // {
            routes = routes // {
              ipv4 = existingV4 ++ extraV4 ++ contractV4;
              ipv6 = existingV6 ++ extraV6 ++ contractV6;
            };
          })
      interfaces;
in
if skipDnsServiceRouteAugmentation then
  target
else
  target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; }
