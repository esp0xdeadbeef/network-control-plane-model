{ lib
, helpers
, common
, ipam
, resolveRoutedPrefixes
, enterpriseName
, siteName
, sitePath
, siteAttrs
, inventoryAttrs
, allSiteEntries
, attachments
, domains
, uplinkNames
,
}:

let
  controlPlane = import ./control-plane.nix {
    inherit helpers common inventoryAttrs siteAttrs enterpriseName siteName uplinkNames;
  };
  overlayData = import ./overlay-provisioning.nix {
    inherit lib helpers common ipam inventoryAttrs siteAttrs sitePath enterpriseName allSiteEntries;
    inherit (controlPlane) siteOverlays;
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
  routeNormalizer = import ./normalize-runtime-routes.nix {
    inherit lib common attachments;
    inherit (overlayData) overlayNames;
    inherit (ipv6Data) routedPrefixesByTenant;
  };
in
{
  inherit (controlPlane)
    bgpSiteAsn
    bgpTopology
    routingMode
    siteControlPlaneCfg
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
  inherit (routeNormalizer) normalizeRuntimeTargetRoutes;
  inherit (ipv6Data)
    ipv6Plan
    routedPrefixesByTenant
    ;
}
