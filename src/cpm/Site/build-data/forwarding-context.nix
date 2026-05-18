{
  lib,
  helpers,
  common,
  ipam,
  resolveRoutedPrefixes,
  enterpriseName,
  siteName,
  sitePath,
  siteAttrs,
  inventoryAttrs,
  allSiteEntries,
  domains,
  uplinkNames,
  allowedRelations,
  attachments,
  nodes,
  serviceDefinitions,
  providerEndpointForServiceProvider,
  providerTenantsForServiceProvider,
  dnsServiceRouteSpecs,
}:

let
  controlPlane = import ./control-plane.nix {
    inherit helpers common inventoryAttrs enterpriseName siteName uplinkNames;
  };
  overlayData = import ./overlay-provisioning.nix {
    inherit lib helpers common ipam siteAttrs sitePath;
    inherit (controlPlane) siteOverlays;
  };
  overlayTransit = import ../../ControlModule/overlay-transit/context.nix {
    inherit lib helpers common allSiteEntries sitePath;
    inherit (overlayData) overlayNames overlayProvisioning;
  };
  routeHelpers = import ../../ControlModule/route-helpers.nix { inherit lib helpers common ipam; };
  augmentRuntimeTargetRoutes = import ../../ControlModule/route-augmentation {
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
      dnsServiceRouteSpecs
      ;
    inherit (overlayData) overlayNames;
    inherit (overlayTransit) overlayTransitEndpointAddressesByOverlay;
  };
  ipv6Data = import ./ipv6-plan.nix {
    inherit
      helpers
      common
      resolveRoutedPrefixes
      enterpriseName
      siteName
      sitePath
      domains
      uplinkNames
      ;
    inherit (controlPlane) siteIpv6Cfg siteTenantsCfg;
  };
in
{
  inherit (controlPlane)
    bgpSiteAsn
    bgpTopology
    routingMode
    siteIpv6Cfg
    siteRouting
    siteTenantsCfg
    siteUplinksCfg
    uplinkRouting
    ;
  inherit (overlayData)
    overlayNames
    overlayProvisioning
    overlayReachability
    ;
  inherit (routeHelpers) normalizeRuntimeTargetRoutes;
  inherit (ipv6Data)
    ipv6Plan
    routedPrefixesByTenant
    ;
  inherit augmentRuntimeTargetRoutes;
}
