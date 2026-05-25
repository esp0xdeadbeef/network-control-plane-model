{
  lib,
  helpers,
  common,
  overlayProvisioning,
  interfaceOverlayLaneNames,
  interfaceOverlayNames,
  p2pPeerAddress,
  defaultViaRoutes,
  overlayNodeRoutesVia,
  overlayPeerTenantRoutes,
  overlayRuntimeRoutedPrefixRoutes,
  overlayRuntimeRoutedPrefixRoutesVia,
  delegatedOverlayDefaultRoutes,
  withoutGenericOverlayDefaults,
  runtimePrefixExitNodes,
  overlayUnderlayEndpoints,
}:

let
  inherit (helpers) hasAttr isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty mergeRoutes;

  underlayEndpointRoutesFor =
    family: overlayNames: routes:
    let
      viaField = if family == 4 then "via4" else "via6";
      endpoints =
        builtins.filter
          (
            endpoint:
            (endpoint.family or null) == family
            && isNonEmptyString (endpoint.sourceFile or null)
            && builtins.elem (endpoint.overlay or null) overlayNames
          )
          overlayUnderlayEndpoints;
    in
    lib.concatMap
      (defaultRoute:
        builtins.map
          (endpoint: {
            inherit family;
            sourceFile = endpoint.sourceFile;
            proto = "underlay";
            overlay = endpoint.overlay;
            intent = {
              kind = "overlay-underlay-reachability";
              source = "overlay-underlay-endpoint";
            };
            ${viaField} = defaultRoute.${viaField};
          })
          endpoints)
      (defaultViaRoutes family routes);

  addOverlayNodeRoutesToSelector =
    nodeRole: interfaces:
    if !(nodeRole == "policy" || nodeRole == "upstream-selector") then
      interfaces
    else
      lib.mapAttrs (
        _: iface:
        let
          laneOverlayNames = builtins.filter (name: builtins.elem name (sortedNames overlayProvisioning)) (
            interfaceOverlayLaneNames iface
          );
          routes = attrsOrEmpty (iface.routes or null);
          extraRoutes = {
            ipv4 = overlayNodeRoutesVia 4 laneOverlayNames (p2pPeerAddress 4 (iface.addr4 or null));
            ipv6 =
              (overlayNodeRoutesVia 6 laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null)))
              ++ (overlayRuntimeRoutedPrefixRoutesVia laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null)));
          };
        in
        if
          (iface.sourceKind or null) != "p2p"
          || laneOverlayNames == [ ]
          || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ])
        then
          iface
        else
          iface // { routes = mergeRoutes routes extraRoutes; }
      ) interfaces;

  addOverlayUnderlayEndpointRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" || overlayUnderlayEndpoints == [ ] then
      interfaces
    else
      let
        nodeOverlayNames = interfaceOverlayNames interfaces;
      in
      if nodeOverlayNames == [ ] then
        interfaces
      else
        lib.mapAttrs (
          _: iface:
          let
            routes = attrsOrEmpty (iface.routes or null);
            extraRoutes = {
              ipv4 = underlayEndpointRoutesFor 4 nodeOverlayNames routes;
              ipv6 = underlayEndpointRoutesFor 6 nodeOverlayNames routes;
            };
          in
          if
            (iface.sourceKind or null) != "p2p"
            || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ])
          then
            iface
          else
            iface // { routes = mergeRoutes routes extraRoutes; }
        ) interfaces;

  addDelegatedOverlayDefaultRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" || runtimePrefixExitNodes == [ ] then
      interfaces
    else
      lib.mapAttrs (
        _: iface:
        let
          routes = attrsOrEmpty (iface.routes or null);
          delegatedDefaults = {
            ipv4 = delegatedOverlayDefaultRoutes 4 routes;
            ipv6 = delegatedOverlayDefaultRoutes 6 routes;
          };
          cleanedRoutes = routes // {
            ipv4 = withoutGenericOverlayDefaults 4 routes;
            ipv6 = withoutGenericOverlayDefaults 6 routes;
          };
        in
        if
          (iface.sourceKind or null) != "overlay"
          || (delegatedDefaults.ipv4 == [ ] && delegatedDefaults.ipv6 == [ ])
        then
          iface
        else
          iface // { routes = mergeRoutes cleanedRoutes delegatedDefaults; }
      ) interfaces;

  addRuntimePrefixReturnsToCoreOverlay =
    nodeRole: interfaces:
    if nodeRole != "core" then
      interfaces
    else
      lib.mapAttrs (
        _: iface:
        let
          overlayName = ((iface.backingRef or { }).name or null);
          routes = attrsOrEmpty (iface.routes or null);
          extraRoutes = {
            ipv4 =
              if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
                builtins.filter (route: (route.family or null) == 4) (overlayPeerTenantRoutes overlayName)
              else
                [ ];
            ipv6 =
              if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
                (builtins.filter (route: (route.family or null) == 6) (overlayPeerTenantRoutes overlayName))
                ++ overlayRuntimeRoutedPrefixRoutes overlayName
              else
                [ ];
          };
        in
        if (iface.sourceKind or null) != "overlay" || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ]) then
          iface
        else
          iface // { routes = mergeRoutes routes extraRoutes; }
      ) interfaces;


in
{
  inherit
    addOverlayNodeRoutesToSelector
    addOverlayUnderlayEndpointRoutesToCore
    addDelegatedOverlayDefaultRoutesToCore
    addRuntimePrefixReturnsToCoreOverlay
    ;
}
