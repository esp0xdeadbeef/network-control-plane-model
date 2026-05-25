{
  lib,
  helpers,
  common,
  ipam,
  overlayProvisioning,
  attachments,
  routedPrefixesByTenant,
}:

let
  inherit (helpers) hasAttr isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;

  base = import ./overlay-route-augmentation/base.nix {
    inherit
      lib
      helpers
      common
      ipam
      overlayProvisioning
      attachments
      routedPrefixesByTenant
      ;
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
    inherit
      lib
      helpers
      common
      overlayProvisioning
      overlayUnderlayEndpoints
      runtimePrefixExitNodes
      ;
    inherit (base) defaultViaRoutes;
  };
  inherit (routeBuilders)
    delegatedOverlayDefaultRoutes
    delegatedOverlayDefaultsVia
    delegatedOverlayExitDefaultsVia
    defaultViaRoutes
    defaultReachabilityVia
    overlayEndpointRoutesVia
    overlayNodeRoutesVia
    overlayPeerTenantRoutes
    overlayRuntimeRoutedPrefixRoutes
    overlayRuntimeRoutedPrefixRoutesVia
    underlayEndpointRoutes
    withoutGenericOverlayDefaults
    ;

  selectorRoutes = import ./overlay-route-augmentation/selector.nix {
    inherit
      lib
      helpers
      overlayProvisioning
      runtimePrefixExitNodes
      p2pPeerAddress
      defaultReachabilityVia
      ;
  };
  inherit (selectorRoutes)
    accessOverlayDefaults
    overlayIngressPolicyDefaults
    ;

  coreRouteAugmenters = import ./overlay-route-augmentation/core-routes.nix {
    inherit
      lib
      helpers
      common
      overlayProvisioning
      interfaceOverlayLaneNames
      interfaceOverlayNames
      p2pPeerAddress
      defaultViaRoutes
      overlayNodeRoutesVia
      overlayPeerTenantRoutes
      overlayRuntimeRoutedPrefixRoutes
      overlayRuntimeRoutedPrefixRoutesVia
      delegatedOverlayDefaultRoutes
      withoutGenericOverlayDefaults
      runtimePrefixExitNodes
      overlayUnderlayEndpoints
      ;
  };
  inherit (coreRouteAugmenters)
    addOverlayNodeRoutesToSelector
    addOverlayUnderlayEndpointRoutesToCore
    addDelegatedOverlayDefaultRoutesToCore
    addRuntimePrefixReturnsToCoreOverlay
    ;

  addRuntimePrefixReturnsToWanCore = import ./overlay-route-augmentation/wan-core-returns.nix {
    inherit
      lib
      helpers
      common
      overlayProvisioning
      p2pPeerAddress
      ;
  };

  finalAugmentation = import ./overlay-route-augmentation/upstream-selector-final.nix {
    inherit
      lib
      helpers
      common
      overlayProvisioning
      overlayUnderlayEndpoints
      defaultViaFor
      interfaceOverlayLaneNames
      p2pPeerAddress
      addOverlayNodeRoutesToSelector
      addOverlayUnderlayEndpointRoutesToCore
      addDelegatedOverlayDefaultRoutesToCore
      addRuntimePrefixReturnsToCoreOverlay
      addRuntimePrefixReturnsToWanCore
      underlayEndpointRoutes
      delegatedOverlayDefaultsVia
      delegatedOverlayExitDefaultsVia
      accessOverlayDefaults
      overlayIngressPolicyDefaults
      ;
  };

in
finalAugmentation
