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
  inherit (helpers) isNonEmptyString requireAttrs requireString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;

  laneHelpers = import ../../Site/topology/lane-metadata.nix { inherit helpers; };
  inherit (laneHelpers) interfaceLane laneUplinks;
  inherit (routeHelpers) routeForExactDstWithGateway routeWithExactDstPresent;

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
  isUpstreamSelectorTarget =
    let
      runtimeIfNames =
        builtins.map
          (
            ifName:
            requireString
              "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName"
              ((interfaces.${ifName} or { }).runtimeIfName or null)
          )
          interfaceNames;
      hasCoreIngress = lib.any (name: name == "core" || lib.hasPrefix "core-" name) runtimeIfNames;
      hasPolicyEgress = lib.any (name: lib.hasPrefix "pol-" name || lib.hasPrefix "policy-" name) runtimeIfNames;
    in
    hasCoreIngress && hasPolicyEgress;
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

  findSourceRouteForDestination = import ./dns/source-routes.nix {
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
      ;
  };

  routesWithDnsExtras = import ./dns/extra-routes.nix {
    inherit helpers common findSourceRouteForDestination routePresent;
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
          hasDefault4 = routeForExactDstWithGateway 4 existingV4 "0.0.0.0/0" != null;
          hasDefault6 = routeForExactDstWithGateway 6 existingV6 "::/0" != null;
          matchesPreferredLane =
            spec:
            let
              preferredUplinks = listOrEmpty (spec.preferredUplinks or null);
            in
            preferredUplinks != [ ]
            && isUpstreamSelectorTarget
            && laneMatchesPreferredUplinks iface preferredUplinks;
          matchesPreferredIngress =
            spec:
            let
              preferredUplinks = listOrEmpty (spec.ingressPreferredUplinks or null);
            in
            preferredUplinks != [ ]
            && isUpstreamSelectorTarget
            && laneMatchesPreferredUplinks iface preferredUplinks;
          matchingSpecs =
            builtins.filter
              (spec:
                builtins.any (destination: routeWithExactDstPresent existingV4 destination) spec.consumerPrefixes4
                || builtins.any (destination: routePresent 6 existingV6 destination) spec.consumerPrefixes6
                || matchesPreferredLane spec
                || matchesPreferredIngress spec)
              dnsServiceRouteSpecs;
          extraV4 = routesWithDnsExtras 4 ifName existingV4 targetExistingV4 matchingSpecs;
          extraV6 = routesWithDnsExtras 6 ifName existingV6 targetExistingV6 matchingSpecs;
        in
        if extraV4 == [ ] && extraV6 == [ ] then
          iface
        else
          iface // { routes = routes // { ipv4 = existingV4 ++ extraV4; ipv6 = existingV6 ++ extraV6; }; })
      interfaces;
in
if skipDnsServiceRouteAugmentation then
  target
else
  target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; }
