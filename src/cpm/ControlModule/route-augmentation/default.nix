{
  lib,
  helpers,
  common,
  ipam,
  routeHelpers,
  sitePath,
  dnsServiceRouteSpecs,
  allowedRelations,
  attachments,
  nodes,
  serviceDefinitions,
  providerEndpointForServiceProvider,
  providerTenantsForServiceProvider,
  overlayNames,
  overlayTransitEndpointAddressesByOverlay,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;

  siteOverlayNameSet = builtins.listToAttrs (map (name: { inherit name; value = true; }) overlayNames);

  routesFor = family: iface:
    let routes = attrsOrEmpty (iface.routes or null);
    in if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);

  routesContainDefault = family: routes:
    let defaultDst = if family == 4 then "0.0.0.0/0" else "::/0";
    in builtins.any (route: builtins.isAttrs route && (route.dst or null) == defaultDst) (listOrEmpty routes);

  serviceIngressContext = import ./service-ingress/context.nix {
    inherit lib helpers common allowedRelations serviceDefinitions providerEndpointForServiceProvider;
  };
  inherit (serviceIngressContext) serviceIngressRelations;

  targetInterfaces = target:
    attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);

  anyInterface = predicate: target:
    let interfaces = targetInterfaces target;
    in builtins.any (ifName: predicate interfaces.${ifName}) (sortedNames interfaces);

  overlayTransitNeeded =
    target:
    overlayNames != [ ]
    && anyInterface
      (iface:
        let
          backingRef = attrsOrEmpty (iface.backingRef or null);
          routes4 = routesFor 4 iface;
          routes6 = routesFor 6 iface;
        in
        (backingRef.kind or null) == "overlay"
        || builtins.any
          (overlayName:
            let overlay = attrsOrEmpty (overlayTransitEndpointAddressesByOverlay.${overlayName} or null);
            in
            builtins.any (dst: routeHelpers.routeWithExactDstPresent routes4 dst) (listOrEmpty (overlay.peerPrefixes4 or null))
            || builtins.any (dst: routeHelpers.routeWithExactDstPresent routes6 dst) (listOrEmpty (overlay.peerPrefixes6 or null)))
          overlayNames)
      target;

  overlayUnderlayNeeded =
    target:
    overlayTransitEndpointAddressesByOverlay != { }
    && anyInterface
      (iface:
        let
          backingRef = attrsOrEmpty (iface.backingRef or null);
          uplinks = listOrEmpty (backingRef.uplinks or null);
          targetsUnderlay = uplinks != [ ] && !builtins.any (uplink: builtins.hasAttr uplink siteOverlayNameSet) uplinks;
        in
        targetsUnderlay
        && (routesContainDefault 4 (routesFor 4 iface) || routesContainDefault 6 (routesFor 6 iface)))
      target;

  serviceIngressNeeded =
    target:
    serviceIngressRelations != [ ]
    && anyInterface
      (iface:
        let
          backingRef = attrsOrEmpty (iface.backingRef or null);
          lane = attrsOrEmpty (backingRef.lane or null);
        in
        (backingRef.kind or null) == "link"
        || (lane.kind or null) == "uplink"
        || (lane.kind or null) == "access-uplink"
        || (routesFor 4 iface) != [ ]
        || (routesFor 6 iface) != [ ])
      target;

  augmentDnsServiceRoutesForTarget = import ./dns.nix {
    inherit lib helpers common ipam routeHelpers sitePath dnsServiceRouteSpecs;
  };

  needsDnsRouteAugmentation = import ./dns-needed.nix {
    inherit helpers common routeHelpers;
  };

  augmentServiceIngressRoutesForTarget = import ./service-ingress.nix {
    inherit
      lib
      helpers
      common
      ipam
      routeHelpers
      sitePath
      allowedRelations
      attachments
      nodes
      serviceDefinitions
      providerEndpointForServiceProvider
      providerTenantsForServiceProvider
      ;
  };

  augmentOverlayTransitEndpointRoutesForTarget = import ./overlay-transit.nix {
    inherit helpers common routeHelpers sitePath overlayNames overlayTransitEndpointAddressesByOverlay;
  };

  augmentOverlayUnderlayEndpointRoutesForTarget = import ./overlay-underlay.nix {
    inherit common helpers routeHelpers overlayTransitEndpointAddressesByOverlay;
    inherit siteOverlayNameSet;
  };

  augmentTarget =
    runtimeTargets: targetName:
    let
      defaultReachabilityTarget = runtimeTargets.${targetName};
      withOverlayUnderlayRoutes =
        if overlayUnderlayNeeded defaultReachabilityTarget then
          augmentOverlayUnderlayEndpointRoutesForTarget targetName defaultReachabilityTarget
        else
          defaultReachabilityTarget;
      withOverlayTransitRoutes =
        if overlayTransitNeeded withOverlayUnderlayRoutes then
          augmentOverlayTransitEndpointRoutesForTarget targetName withOverlayUnderlayRoutes
        else
          withOverlayUnderlayRoutes;
      withServiceIngressRoutes =
        if serviceIngressNeeded withOverlayTransitRoutes then
          augmentServiceIngressRoutesForTarget targetName withOverlayTransitRoutes
        else
          withOverlayTransitRoutes;
    in
    if needsDnsRouteAugmentation { inherit dnsServiceRouteSpecs; target = withServiceIngressRoutes; } then
      augmentDnsServiceRoutesForTarget targetName withServiceIngressRoutes
    else
      withServiceIngressRoutes;

in
runtimeTargets:
builtins.listToAttrs (
  builtins.map
    (targetName: {
      name = targetName;
      value = augmentTarget runtimeTargets targetName;
    })
    (sortedNames runtimeTargets)
)
