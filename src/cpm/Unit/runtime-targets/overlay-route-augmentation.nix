{ lib
, helpers
, common
, ipam
, overlayProvisioning
, attachments
, routedPrefixesByTenant
,
}:

let
  inherit (helpers) hasAttr isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;

  base = import ./overlay-route-augmentation/base.nix {
    inherit lib helpers common ipam overlayProvisioning attachments routedPrefixesByTenant;
  };
  inherit (base)
    defaultViaFor
    interfaceOverlayLaneNames
    interfaceOverlayNames
    overlayUnderlayEndpoints
    p2pPeerAddress
    runtimePrefixExitNodes
    ;

  routeBuilders = import ./overlay-route-augmentation/routes.nix {
    inherit lib helpers common overlayProvisioning overlayUnderlayEndpoints runtimePrefixExitNodes;
    inherit (base) defaultViaRoutes;
  };
  inherit (routeBuilders)
    delegatedOverlayDefaultRoutes
    delegatedOverlayDefaultsVia
    delegatedOverlayExitDefaultsVia
    defaultReachabilityVia
    overlayEndpointRoutesVia
    overlayNodeRoutesVia
    overlayRuntimeRoutedPrefixRoutes
    overlayRuntimeRoutedPrefixRoutesVia
    underlayEndpointRoutes
    withoutGenericOverlayDefaults
    ;

  selectorRoutes = import ./overlay-route-augmentation/selector.nix {
    inherit lib helpers overlayProvisioning runtimePrefixExitNodes p2pPeerAddress defaultReachabilityVia;
  };
  inherit (selectorRoutes) accessOverlayDefaults;

  addOverlayNodeRoutesToSelector =
    nodeRole: interfaces:
    if !(nodeRole == "policy" || nodeRole == "upstream-selector") then
      interfaces
    else
      lib.mapAttrs
        (_: iface:
        let
          laneOverlayNames = builtins.filter (name: builtins.elem name (sortedNames overlayProvisioning)) (interfaceOverlayLaneNames iface);
          routes = attrsOrEmpty (iface.routes or null);
          extraRoutes = {
            ipv4 = overlayNodeRoutesVia 4 laneOverlayNames (p2pPeerAddress 4 (iface.addr4 or null));
            ipv6 = (overlayNodeRoutesVia 6 laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null))) ++ (overlayRuntimeRoutedPrefixRoutesVia laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null)));
          };
        in
        if (iface.sourceKind or null) != "p2p" || laneOverlayNames == [ ] || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ]) then iface else iface // { routes = mergeRoutes routes extraRoutes; })
        interfaces;

  addOverlayUnderlayEndpointRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" || overlayUnderlayEndpoints == [ ] then
      interfaces
    else
      let nodeOverlayNames = interfaceOverlayNames interfaces;
      in
      if nodeOverlayNames == [ ] then interfaces else
      lib.mapAttrs
        (_: iface:
        let
          laneOverlayNames = builtins.filter (name: builtins.elem name nodeOverlayNames) (interfaceOverlayLaneNames iface);
          peer4 = p2pPeerAddress 4 (iface.addr4 or null);
          peer6 = p2pPeerAddress 6 (iface.addr6 or null);
          routes = attrsOrEmpty (iface.routes or null);
          extraRoutes = {
            ipv4 = (defaultReachabilityVia 4 peer4) ++ (overlayEndpointRoutesVia 4 laneOverlayNames peer4);
            ipv6 = (defaultReachabilityVia 6 peer6) ++ (overlayEndpointRoutesVia 6 laneOverlayNames peer6);
          };
        in
        if (iface.sourceKind or null) != "p2p" || laneOverlayNames == [ ] || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ]) then iface else iface // { routes = mergeRoutes routes extraRoutes; })
        interfaces;

  addDelegatedOverlayDefaultRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" || runtimePrefixExitNodes == [ ] then
      interfaces
    else
      lib.mapAttrs
        (_: iface:
        let
          routes = attrsOrEmpty (iface.routes or null);
          delegatedDefaults = {
            ipv4 = delegatedOverlayDefaultRoutes 4 routes;
            ipv6 = delegatedOverlayDefaultRoutes 6 routes;
          };
          cleanedRoutes =
            routes
            // {
              ipv4 = withoutGenericOverlayDefaults 4 routes;
              ipv6 = withoutGenericOverlayDefaults 6 routes;
            };
        in
        if (iface.sourceKind or null) != "overlay" || (delegatedDefaults.ipv4 == [ ] && delegatedDefaults.ipv6 == [ ]) then
          iface
        else
          iface // { routes = mergeRoutes cleanedRoutes delegatedDefaults; })
        interfaces;

  addRuntimePrefixReturnsToCoreOverlay =
    nodeRole: interfaces:
    if nodeRole != "core" then
      interfaces
    else
      lib.mapAttrs
        (_: iface:
        let
          overlayName = ((iface.backingRef or { }).name or null);
          routes = attrsOrEmpty (iface.routes or null);
          extraRoutes = {
            ipv4 = [ ];
            ipv6 = if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then overlayRuntimeRoutedPrefixRoutes overlayName else [ ];
          };
        in
        if (iface.sourceKind or null) != "overlay" || extraRoutes.ipv6 == [ ] then
          iface
        else
          iface // { routes = mergeRoutes routes extraRoutes; })
        interfaces;

  addRuntimePrefixReturnsToWanCore =
    import ./overlay-route-augmentation/wan-core-returns.nix {
      inherit lib helpers common overlayProvisioning p2pPeerAddress;
    };

in
nodeRole: interfaces:
let
  selectorDefaultVia4 = defaultViaFor 4 interfaces;
  selectorDefaultVia6 = defaultViaFor 6 interfaces;
  coreInterfaces =
    addRuntimePrefixReturnsToWanCore nodeRole (
      addRuntimePrefixReturnsToCoreOverlay nodeRole (
        addDelegatedOverlayDefaultRoutesToCore nodeRole (
          addOverlayUnderlayEndpointRoutesToCore nodeRole (addOverlayNodeRoutesToSelector nodeRole interfaces)
        )
      )
    );
in
if nodeRole != "upstream-selector" || overlayUnderlayEndpoints == [ ] then
  coreInterfaces
else
  lib.mapAttrs
    (_: iface:
    let
      laneOverlayNames = builtins.filter (name: builtins.elem name (sortedNames overlayProvisioning)) (interfaceOverlayLaneNames iface);
      routes = attrsOrEmpty (iface.routes or null);
      policyDefaults =
        builtins.filter
          (route: (route.policyOnly or false) == true && ((route.intent or { }).kind or null) == "default-reachability")
          ((listOrEmpty (routes.ipv4 or null)) ++ (listOrEmpty (routes.ipv6 or null)));
      peer4 = p2pPeerAddress 4 (iface.addr4 or null);
      peer6 = p2pPeerAddress 6 (iface.addr6 or null);
      accessDefaults = accessOverlayDefaults iface coreInterfaces;
      delegatedDefaults =
        if (iface.sourceKind or null) == "p2p" && laneOverlayNames != [ ] then
          {
            ipv4 =
              if policyDefaults != [ ] then
                delegatedOverlayExitDefaultsVia 4 peer4
              else
                delegatedOverlayDefaultsVia 4 laneOverlayNames selectorDefaultVia4;
            ipv6 =
              if policyDefaults != [ ] then
                delegatedOverlayExitDefaultsVia 6 peer6
              else
                delegatedOverlayDefaultsVia 6 laneOverlayNames selectorDefaultVia6;
          }
        else
          { ipv4 = [ ]; ipv6 = [ ]; };
      extraRoutes = {
        ipv4 = (underlayEndpointRoutes 4 routes) ++ delegatedDefaults.ipv4 ++ accessDefaults.ipv4;
        ipv6 = (underlayEndpointRoutes 6 routes) ++ delegatedDefaults.ipv6 ++ accessDefaults.ipv6;
      };
    in
    if extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ] then iface else iface // { routes = mergeRoutes routes extraRoutes; })
    coreInterfaces
