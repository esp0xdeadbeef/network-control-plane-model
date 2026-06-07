{ lib
, helpers
, common
, realizationIndex
, enterpriseName
, siteName
, sitePath
, attachments
, links
, nodes
, policyNodeName
, routingMode
, bgpSiteAsn
, bgpTopology
, uplinkRouting
, overlayProvisioning
, overlayNames
, siteOverlays
, siteIpv6Cfg
, siteTenantsCfg
, routedPrefixesByTenant
, policyDerivedDnsAllowFromForListeners
, policyDerivedDnsAllowedClassesForListeners
, policyDerivedDnsAllowedClassesForTenants
, policyDerivedDnsDirectEgressBlockedTenants
, policyDerivedDnsDirectEgressBlockedForListeners
, policyDerivedDnsDirectEgressBlockedForTenants
, policyDerivedDnsForwardersForListeners
, policyDerivedDnsForwardersForTenants
, policyDerivedDnsUpstreamRecordsForListeners
,
}:

let
  inherit (common) attrsOrEmpty failInventory uniqueStrings;

  backingRefResolver = import ../../Unit/runtime-targets/interfaces/backing-ref.nix {
    inherit lib helpers common enterpriseName siteName sitePath attachments links;
  };

  hostUplinkValidator = import ../../Unit/runtime-targets/interfaces/host-uplink.nix {
    inherit helpers common;
  };

  buildExplicitInterfaceEntry = import ../../Unit/runtime-targets/interfaces/explicit.nix {
    inherit helpers common sitePath overlayProvisioning uplinkRouting siteIpv6Cfg siteTenantsCfg routedPrefixesByTenant;
    inherit (backingRefResolver) resolveBackingRef;
    inherit (hostUplinkValidator) requireExplicitHostUplinkAddressing;
  };

  buildSyntheticUplinkInterfaceEntry = import ../../Unit/runtime-targets/interfaces/synthetic-uplink.nix {
    inherit helpers common sitePath enterpriseName siteName overlayNames uplinkRouting;
    inherit (hostUplinkValidator) requireExplicitHostUplinkAddressing;
  };

  buildInventoryOverlayRuntimeAdapterEntry = import ../../Unit/runtime-targets/interfaces/inventory-overlay-runtime-adapter.nix {
    inherit helpers common sitePath enterpriseName siteName;
  };

  runtimeServices = import ../../Unit/runtime-services {
    inherit
      lib
      helpers
      sitePath
      attachments
      attrsOrEmpty
      failInventory
      policyDerivedDnsAllowFromForListeners
      policyDerivedDnsAllowedClassesForListeners
      policyDerivedDnsAllowedClassesForTenants
      policyDerivedDnsDirectEgressBlockedTenants
      policyDerivedDnsDirectEgressBlockedForListeners
      policyDerivedDnsDirectEgressBlockedForTenants
      policyDerivedDnsForwardersForListeners
      policyDerivedDnsForwardersForTenants
      policyDerivedDnsUpstreamRecordsForListeners
      uniqueStrings
      ;
  };

  runtimeContainers = import ../../Unit/runtime-targets/containers.nix {
    inherit helpers common sitePath;
  };

  runtimeBgp = import ../../Unit/runtime-targets/bgp.nix {
    inherit lib helpers common sitePath nodes policyNodeName bgpSiteAsn routedPrefixesByTenant;
  };

  runtimeTargetBuilder = import ../../Unit/runtime-targets {
    inherit
      lib
      helpers
      common
      realizationIndex
      enterpriseName
      siteName
      sitePath
      nodes
      routingMode
      bgpSiteAsn
      bgpTopology
      uplinkRouting
      overlayProvisioning
      siteOverlays
      attachments
      routedPrefixesByTenant
      buildExplicitInterfaceEntry
      buildSyntheticUplinkInterfaceEntry
      buildInventoryOverlayRuntimeAdapterEntry
      ;
    inherit (runtimeServices)
      resolveRuntimeServices
      ;
    inherit (runtimeContainers)
      resolveRuntimeContainers
      ;
    inherit (runtimeBgp)
      bgpNetworksForNode
      bgpNeighborsForNode
      filterRoutesForBgp
      routerRoleSet
      ;
  };

in
{
  initialRuntimeTargets = runtimeTargetBuilder.runtimeTargets;
}
