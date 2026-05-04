{
  lib,
  helpers,
  common,
  routeHelpers,
  sitePath,
  dnsServiceRouteSpecs,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs requireString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;
  inherit (routeHelpers)
    routeForExactDstWithGateway
    routeWithDstAndGatewayPresent
    routeWithExactDstPresent
    ;
  p2pPeers = import ./p2p-peers.nix { inherit lib; };
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

  findSourceRouteForDestination =
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
          exact = routeForExactDstWithGateway family routes destination;
          peer = p2pPeers.peerForInterface family interfaces.${ifName};
        in
        if exact != null then
          exact
        else if includeConsumerInterface && ifName == consumerInterfaceName && isNonEmptyString peer then
          {
            dst = destination;
            proto = "default";
          }
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
            familyRoutes = if family == 4 then listOrEmpty (candidateRoutes.ipv4 or null) else listOrEmpty (candidateRoutes.ipv6 or null);
          in
          routeForDestinationOrDefault ifName familyRoutes)
        candidateInterfaceNames);

  routesWithDnsExtras =
    family: ifName: existingRoutes: matchingSpecs:
    builtins.foldl'
      (acc: spec:
        let
          preferredUplinks = listOrEmpty (spec.preferredUplinks or null);
          serviceDestinations =
            (if family == 4 then spec.providerPrefixes4 else spec.providerPrefixes6)
            ++ (if family == 4 then spec.providerAddresses4 or [ ] else spec.providerAddresses6 or [ ]);
        in
        builtins.foldl'
          (inner: destination:
            let
              sourceRoute = findSourceRouteForDestination family ifName preferredUplinks destination;
              gateway = if sourceRoute == null then null else if family == 4 then sourceRoute.via4 or null else sourceRoute.via6 or null;
              extraRoute =
                if sourceRoute == null || !isNonEmptyString gateway then
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
            if extraRoute == null || routeWithDstAndGatewayPresent family (existingRoutes ++ inner) destination gateway then
              inner
            else
              inner ++ [ extraRoute ])
          acc
          serviceDestinations)
      [ ]
      matchingSpecs;

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
                || builtins.any (destination: routeWithExactDstPresent existingV6 destination) spec.consumerPrefixes6
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
