{
  helpers,
  common,
  siteOverlayNameSet,
  overlayExitPeerSiteByName ? { },
}:

let
  inherit (common) attrsOrEmpty defaultDst listOrEmpty;

  interfaceSelection = import ./delegated-overlay-egress/interface-selection.nix {
    inherit helpers common siteOverlayNameSet;
  };
  inherit (interfaceSelection)
    egressInterfaceNames
    ingressInterfaceNames
    isOverlayInterface
    overlayNameForInterface
    ;

  delegatedRouteExists =
    family: sourceNode: routes:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.dst or null) == defaultDst family
        && ((attrsOrEmpty (route.intent or null)).kind or null) == "delegated-public-egress"
        && ((attrsOrEmpty (route.intent or null)).exitNode or null) == sourceNode)
      (listOrEmpty routes);

  firstGateway =
    family: routes:
    let
      field = if family == 4 then "via4" else "via6";
      candidates = builtins.filter (route: route.${field} or null != null) routes;
    in
    if candidates == [ ] then null else (builtins.head candidates).${field};

  gatewayForInterface =
    family: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      existingRoutes = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
    in
    firstGateway family existingRoutes;

  firstOverlayGateway =
    family: targetRole: interfaces:
    let
      candidates =
        builtins.filter
          (gateway: gateway != null)
          (builtins.map (ifName: gatewayForInterface family interfaces.${ifName}) (egressInterfaceNames targetRole interfaces));
    in
    if candidates == [ ] then null else builtins.head candidates;

  delegatedOverlayRoute =
    family: sourceNode: metric: gatewayOverride: overlayName: iface: existingRoutes:
    let
      gateway = if gatewayOverride != null then gatewayOverride else firstGateway family existingRoutes;
      peerSite = if overlayName == null then null else overlayExitPeerSiteByName.${overlayName} or null;
      overlayContract =
        if overlayName == null || peerSite == null then
          { }
        else
          {
            family = family;
            overlay = overlayName;
            peerSite = peerSite;
          };
      base = {
        dst = defaultDst family;
        intent = {
          kind = "delegated-public-egress";
          source = "external-validation";
          exitNode = sourceNode;
        };
        metric = metric;
        policyOnly = true;
        proto = "overlay";
      } // overlayContract;
    in
    if isOverlayInterface iface then
      base // { scope = "link"; }
    else if gateway == null then
      base // { scope = "link"; }
    else
      base // (if family == 4 then { via4 = gateway; } else { via6 = gateway; });

  addToInterface =
    family: sourceNode: metric: gatewayOverride: requireGateway: ifName: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      existingRoutes = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
    in
    if delegatedRouteExists family sourceNode existingRoutes || (requireGateway && gatewayOverride == null) then
      iface
    else
      iface
      // {
        routes =
          routes
          // (
            if family == 4 then
              { ipv4 = existingRoutes ++ [ (delegatedOverlayRoute family sourceNode metric gatewayOverride (overlayNameForInterface ifName iface) iface existingRoutes) ]; }
            else
              { ipv6 = existingRoutes ++ [ (delegatedOverlayRoute family sourceNode metric gatewayOverride (overlayNameForInterface ifName iface) iface existingRoutes) ]; }
          );
      };
in
{
  add =
    {
      family,
      sourceNode,
      metric,
      targetRole,
      interfaces,
    }:
    let
      withEgress =
        builtins.foldl'
          (acc: ifName: acc // { ${ifName} = addToInterface family sourceNode metric null false ifName acc.${ifName}; })
          interfaces
          (egressInterfaceNames targetRole interfaces);
      overlayGateway = firstOverlayGateway family targetRole withEgress;
    in
    builtins.foldl'
      (acc: ifName: acc // { ${ifName} = addToInterface family sourceNode metric overlayGateway true ifName acc.${ifName}; })
      withEgress
      (ingressInterfaceNames sourceNode withEgress);
}
