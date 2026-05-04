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
  inherit (routeHelpers) routeForExactDstWithGateway routeWithExactDstPresent;

  destinationHelpers = import ./dns/destinations.nix {
    inherit lib common ipam routeHelpers;
  };
  inherit (destinationHelpers)
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
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = backingRef.lane or null;
    in
    preferredUplinks == [ ]
    || (
      isNonEmptyString lane
      && lib.any (
        uplinkName:
        lane == "uplink::${uplinkName}" || lib.hasSuffix "::uplink::${uplinkName}" lane
      ) preferredUplinks
    );

  lanePreservesConsumerPath =
    preferredUplinks: consumerIface: candidateIface:
    let
      consumerLane = (attrsOrEmpty (consumerIface.backingRef or null)).lane or null;
      candidateLane = (attrsOrEmpty (candidateIface.backingRef or null)).lane or null;
    in
    preferredUplinks == [ ]
    || !isNonEmptyString consumerLane
    || !isNonEmptyString candidateLane
    || candidateLane == consumerLane
    || lib.hasPrefix "${consumerLane}::" candidateLane;

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
      routeForCanonicalDstWithGateway
      ;
  };

  routesWithDnsExtras = import ./dns/extra-routes.nix {
    inherit helpers common findSourceRouteForDestination routePresent;
  };

  updatedInterfaces =
    builtins.mapAttrs
      (ifName: iface:
        let
          routes = attrsOrEmpty (iface.routes or null);
          existingV4 = listOrEmpty (routes.ipv4 or null);
          existingV6 = listOrEmpty (routes.ipv6 or null);
          hasDefault4 = routeForExactDstWithGateway 4 existingV4 "0.0.0.0/0" != null;
          hasDefault6 = routeForExactDstWithGateway 6 existingV6 "::/0" != null;
          matchesPreferredDefault =
            spec:
            let
              preferredUplinks = listOrEmpty (spec.preferredUplinks or null);
            in
            preferredUplinks != [ ]
            && isUpstreamSelectorTarget
            && laneMatchesPreferredUplinks iface preferredUplinks
            && (hasDefault4 || hasDefault6);
          matchingSpecs =
            builtins.filter
              (spec:
                builtins.any (destination: routeWithExactDstPresent existingV4 destination) spec.consumerPrefixes4
                || builtins.any (destination: routePresent 6 existingV6 destination) spec.consumerPrefixes6
                || matchesPreferredDefault spec)
              dnsServiceRouteSpecs;
          extraV4 = routesWithDnsExtras 4 ifName existingV4 matchingSpecs;
          extraV6 = routesWithDnsExtras 6 ifName existingV6 matchingSpecs;
        in
        if extraV4 == [ ] && extraV6 == [ ] then
          iface
        else
          iface // { routes = routes // { ipv4 = existingV4 ++ extraV4; ipv6 = existingV6 ++ extraV6; }; })
      interfaces;
in
target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; }
