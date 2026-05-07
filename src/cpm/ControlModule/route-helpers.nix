{ lib, helpers, common, ipam }:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty;

  canonicalDestination =
    destination:
    let
      cidr = ipam.splitCIDR destination;
    in
    if cidr == null then
      destination
    else
      let
        parsed6 = ipam.parseIPv6 cidr.addr;
        parsed4 = ipam.parseIPv4 cidr.addr;
      in
      if parsed6 != null then
        "${ipam.renderIPv6 parsed6}/${toString cidr.prefixLen}"
      else if parsed4 != null then
        "${ipam.renderIPv4 parsed4}/${toString cidr.prefixLen}"
      else
        destination;

  routeWithDstPresent =
    family: routes: destination:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.dst or null) == (if family == 4 then "${destination}/32" else "${destination}/128"))
      (listOrEmpty routes);

  routeWithExactDstPresent =
    routes: destination:
    let
      expected = canonicalDestination destination;
    in
    builtins.any
      (route: builtins.isAttrs route && canonicalDestination (route.dst or null) == expected)
      (listOrEmpty routes);

  routeWithDstAndGatewayPresent =
    family: routes: destination: gateway:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.dst or null) == destination
        && (if family == 4 then (route.via4 or null) == gateway else (route.via6 or null) == gateway))
      (listOrEmpty routes);

  routeForExactDstWithGateway =
    family: routes: destination:
    let
      expected = canonicalDestination destination;
    in
    lib.findFirst
      (route:
        builtins.isAttrs route
        && canonicalDestination (route.dst or null) == expected
        && (if family == 4 then isNonEmptyString (route.via4 or null) else isNonEmptyString (route.via6 or null)))
      null
      (listOrEmpty routes);

  routeGatewayForPrefix =
    family: routes: destinations:
    let
      expectedDestinations = builtins.map canonicalDestination destinations;
      matchingRoute =
        lib.findFirst
          (route:
            builtins.isAttrs route
            && builtins.elem (canonicalDestination (route.dst or null)) expectedDestinations
            && (if family == 4 then isNonEmptyString (route.via4 or null) else isNonEmptyString (route.via6 or null)))
          null
          (listOrEmpty routes);
    in
    if matchingRoute == null then null else if family == 4 then matchingRoute.via4 else matchingRoute.via6;

  buildOverlayTransitEndpointRoute =
    family: overlayName: peerSite: destination: destinationNode: gateway:
    {
      dst = if family == 4 then "${destination}/32" else "${destination}/128";
      intent = {
        kind = "overlay-reachability";
        source = "transit-endpoint";
        node = destinationNode;
      };
      proto = "overlay";
      overlay = overlayName;
      peerSite = peerSite;
    }
    // (
      if gateway == null then
        { }
      else if family == 4 then
        { via4 = gateway; }
      else
        { via6 = gateway; }
    );

  buildOverlayUnderlayEndpointRoute =
    family: overlayName: destination: gateway:
    {
      dst = if family == 4 then "${destination}/32" else "${destination}/128";
      intent = {
        kind = "overlay-underlay-reachability";
        source = "overlay-underlay-endpoint";
      };
      proto = "underlay";
      overlay = overlayName;
    }
    // (
      if family == 4 then
        { via4 = gateway; }
      else
        { via6 = gateway; }
    );

  routeKey =
    family: route:
    if !builtins.isAttrs route then
      null
    else
      builtins.toJSON {
        inherit family;
        dst = route.dst or null;
        table = route.table or null;
        via4 = route.via4 or null;
        via6 = route.via6 or null;
        scope = route.scope or null;
      };

  uniqueRoutes =
    family: routes:
    (builtins.foldl'
      (acc: route:
        let
          key = routeKey family route;
        in
        if key == null || builtins.hasAttr key acc.seen then
          acc
        else
          {
            seen = acc.seen // { ${key} = true; };
            values = acc.values ++ [ route ];
          })
      { seen = { }; values = [ ]; }
      routes).values;

  normalizeRuntimeTargetRoutes =
    target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      normalizedInterfaces =
        builtins.mapAttrs
          (_ifName: iface:
            let
              routes = attrsOrEmpty (iface.routes or null);
              ipv4 = listOrEmpty (routes.ipv4 or null);
              ipv6 = listOrEmpty (routes.ipv6 or null);
            in
            if ipv4 == [ ] && ipv6 == [ ] then
              iface
            else
              iface // { routes = routes // { ipv4 = uniqueRoutes 4 ipv4; ipv6 = uniqueRoutes 6 ipv6; }; })
          interfaces;
    in
    if interfaces == { } then target else target // { effectiveRuntimeRealization = effective // { interfaces = normalizedInterfaces; }; };
in
{
  inherit
    buildOverlayTransitEndpointRoute
    buildOverlayUnderlayEndpointRoute
    normalizeRuntimeTargetRoutes
    routeForExactDstWithGateway
    routeGatewayForPrefix
    routeWithDstAndGatewayPresent
    routeWithDstPresent
    routeWithExactDstPresent
    uniqueRoutes
    ;
}
