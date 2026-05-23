{
  lib,
  helpers,
  common,
  overlayProvisioning,
  interfaceOverlayLaneNames,
  interfaceOverlayNames,
  p2pPeerAddress,
  defaultReachabilityVia,
  overlayEndpointRoutesVia,
  overlayNodeRoutesVia,
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
            laneOverlayNames = builtins.filter (name: builtins.elem name nodeOverlayNames) (
              interfaceOverlayLaneNames iface
            );
            peer4 = p2pPeerAddress 4 (iface.addr4 or null);
            peer6 = p2pPeerAddress 6 (iface.addr6 or null);
            routes = attrsOrEmpty (iface.routes or null);
            extraRoutes = {
              ipv4 = (defaultReachabilityVia 4 peer4) ++ (overlayEndpointRoutesVia 4 laneOverlayNames peer4);
              ipv6 = (defaultReachabilityVia 6 peer6) ++ (overlayEndpointRoutesVia 6 laneOverlayNames peer6);
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
            ipv4 = [ ];
            ipv6 =
              if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
                overlayRuntimeRoutedPrefixRoutes overlayName
              else
                [ ];
          };
        in
        if (iface.sourceKind or null) != "overlay" || extraRoutes.ipv6 == [ ] then
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
