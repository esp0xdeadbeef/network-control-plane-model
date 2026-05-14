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

  isFamilyDestination =
    family: destination:
    builtins.isString destination
    && destination != ""
    && (if family == 4 then builtins.match ".*:.*" destination == null else builtins.match ".*:.*" destination != null);

  dnsContractDestinations =
    family:
    let
      dns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
      routeContracts = listOrEmpty (dns.routeContracts or null);
      forwarders = listOrEmpty (dns.forwarders or null);
    in
    lib.unique (
      builtins.filter
        (destination: isFamilyDestination family destination)
        ((map (contract: (attrsOrEmpty contract).dst or null) routeContracts) ++ forwarders)
    );

  routeForDnsContract =
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

  dnsContractRoutesForInterface =
    family: iface: existingRoutes:
    let
      destinations = dnsContractDestinations family;
    in
    if (target.role or null) != "access" || (iface.sourceKind or null) != "p2p" || destinations == [ ] then
      [ ]
    else
      builtins.foldl'
        (acc: destination:
          let route = routeForDnsContract family existingRoutes destination;
          in
          if route == null || routePresent family (existingRoutes ++ acc) destination then
            acc
          else
            acc ++ [ route ])
        [ ]
        destinations;

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
    inherit helpers common interfaces isUpstreamSelectorTarget findSourceRouteForDestination routePresent;
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
          contractV4 = dnsContractRoutesForInterface 4 iface (existingV4 ++ extraV4);
          contractV6 = dnsContractRoutesForInterface 6 iface (existingV6 ++ extraV6);
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
