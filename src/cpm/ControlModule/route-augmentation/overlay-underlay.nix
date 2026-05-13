{
  common,
  helpers,
  routeHelpers,
  siteOverlayNameSet,
  overlayTransitEndpointAddressesByOverlay,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;
  inherit (routeHelpers) buildOverlayUnderlayEndpointRoute routeWithDstPresent;

  isIPv6 = value: builtins.match ".*:.*" value != null;

  routesContainDefault =
    family: routes:
    let defaultDst = if family == 4 then "0.0.0.0/0" else "::/0";
    in builtins.any (route: builtins.isAttrs route && (route.dst or null) == defaultDst) (listOrEmpty routes);

  routeGateway =
    family: routes:
    let
      defaultRoutes = builtins.filter (route: routesContainDefault family [ route ]) routes;
      route = if defaultRoutes == [ ] then { } else builtins.head defaultRoutes;
    in
    if family == 4 then route.via4 or null else route.via6 or null;

  interfaceUplinkNames =
    iface:
    let backingRef = attrsOrEmpty (iface.backingRef or null);
    in listOrEmpty (backingRef.uplinks or null);

  interfaceTargetsUnderlay =
    iface:
    let uplinks = interfaceUplinkNames iface;
    in uplinks != [ ] && !builtins.any (uplink: builtins.hasAttr uplink siteOverlayNameSet) uplinks;

  endpointFamilyMatches =
    family: endpoint:
    if builtins.isString endpoint then
      isNonEmptyString endpoint && (if family == 6 then isIPv6 endpoint else !isIPv6 endpoint)
    else
      builtins.isAttrs endpoint && (endpoint.family or null) == family && isNonEmptyString (endpoint.sourceFile or null);

  dynamicRouteExists =
    family: routes: endpoint:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.sourceFile or null) == endpoint.sourceFile
        && (route.family or null) == family
        && ((attrsOrEmpty (route.intent or null)).kind or null) == "overlay-underlay-reachability")
      (listOrEmpty routes);

  buildDynamicEndpointRoute =
    family: overlayName: endpoint: gateway:
    {
      inherit family;
      sourceFile = endpoint.sourceFile;
      intent = {
        kind = "overlay-underlay-reachability";
        source = "overlay-underlay-endpoint";
      };
      proto = "underlay";
      overlay = overlayName;
    }
    // (if family == 4 then { via4 = gateway; } else { via6 = gateway; });

  endpointRouteAlreadyPresent =
    family: existingRoutes: endpoint:
    if builtins.isString endpoint then
      routeWithDstPresent family existingRoutes endpoint
    else
      dynamicRouteExists family existingRoutes endpoint;

  buildEndpointRoute =
    family: overlayName: endpoint: gateway:
    if builtins.isString endpoint then
      buildOverlayUnderlayEndpointRoute family overlayName endpoint gateway
    else
      buildDynamicEndpointRoute family overlayName endpoint gateway;

  addRoutesForFamily =
    family: overlayName: gateway: existingRoutes: endpoints:
    if !isNonEmptyString gateway then
      [ ]
    else
      builtins.map
        (endpoint: buildEndpointRoute family overlayName endpoint gateway)
        (builtins.filter
          (endpoint:
            endpointFamilyMatches family endpoint
            && !endpointRouteAlreadyPresent family existingRoutes endpoint)
          endpoints);
in
_targetName: target:
let
  effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
  interfaces = attrsOrEmpty (effective.interfaces or null);
  updatedInterfaces =
    builtins.mapAttrs
      (_: iface:
        let
          routes = attrsOrEmpty (iface.routes or null);
          existingV4 = listOrEmpty (routes.ipv4 or null);
          existingV6 = listOrEmpty (routes.ipv6 or null);
          gateway4 = if routesContainDefault 4 existingV4 then routeGateway 4 existingV4 else null;
          gateway6 = if routesContainDefault 6 existingV6 then routeGateway 6 existingV6 else null;
          endpointRoutes =
            builtins.map
              (overlayName:
                let
                  overlay = attrsOrEmpty (overlayTransitEndpointAddressesByOverlay.${overlayName} or null);
                  endpoints = listOrEmpty (overlay.underlayEndpoints or null);
                in
                {
                  ipv4 = addRoutesForFamily 4 overlayName gateway4 existingV4 endpoints;
                  ipv6 = addRoutesForFamily 6 overlayName gateway6 existingV6 endpoints;
                })
              (sortedNames overlayTransitEndpointAddressesByOverlay);
          extraV4 = builtins.concatLists (builtins.map (entry: entry.ipv4) endpointRoutes);
          extraV6 = builtins.concatLists (builtins.map (entry: entry.ipv6) endpointRoutes);
        in
        if !interfaceTargetsUnderlay iface || (extraV4 == [ ] && extraV6 == [ ]) then
          iface
        else
          iface // { routes = routes // { ipv4 = existingV4 ++ extraV4; ipv6 = existingV6 ++ extraV6; }; })
      interfaces;
in
target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; }
