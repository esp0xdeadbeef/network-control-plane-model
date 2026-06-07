{ lib
, helpers
, common
, ipam
, realizationIndex
, endpointInventoryIndex
, resolveAccessAdvertisements
, resolvePolicyEndpointBindings
, resolveFirewallIntent
, sitePath
, siteAttrs
, transitAttrs
, allSiteEntries
, attachments
, domains
, links
, nodes
, policyNodeName
, bgpSiteAsn
, bgpTopology
, routingMode
, uplinkRouting
, overlayProvisioning
, overlayNames
, siteOverlays
, siteTenantsCfg
, siteIpv6Cfg
, routedPrefixesByTenant
, dnsServiceRouteSpecs
, providerEndpointForServiceProvider
, providerTenantsForServiceProvider
, policyDerivedDnsAllowFromForListeners
, policyDerivedDnsAllowedClassesForListeners
, policyDerivedDnsAllowedClassesForTenants
, policyDerivedDnsDirectEgressBlockedTenants
, policyDerivedDnsDirectEgressBlockedForListeners
, policyDerivedDnsDirectEgressBlockedForTenants
, policyDerivedDnsForwardersForListeners
, policyDerivedDnsForwardersForTenants
, policyDerivedDnsUpstreamRecordsForListeners
, normalizeRuntimeTargetRoutes
, normalizeRuntimeTargetRoutesAfterPolicyComplements
, enterpriseName
, siteName
,
}:

let
  runtimeTargetContext = import ./runtime-target-context.nix {
    inherit
      lib
      helpers
      common
      realizationIndex
      enterpriseName
      siteName
      sitePath
      attachments
      links
      nodes
      policyNodeName
      routingMode
      bgpSiteAsn
      bgpTopology
      uplinkRouting
      overlayProvisioning
      overlayNames
      siteOverlays
      siteIpv6Cfg
      siteTenantsCfg
      routedPrefixesByTenant
      policyDerivedDnsAllowFromForListeners
      policyDerivedDnsAllowedClassesForListeners
      policyDerivedDnsAllowedClassesForTenants
      policyDerivedDnsDirectEgressBlockedTenants
      policyDerivedDnsDirectEgressBlockedForListeners
      policyDerivedDnsDirectEgressBlockedForTenants
      policyDerivedDnsForwardersForListeners
      policyDerivedDnsForwardersForTenants
      policyDerivedDnsUpstreamRecordsForListeners
      ;
  };

  normalizedRuntimeTargets =
    builtins.mapAttrs (_targetName: normalizeRuntimeTargetRoutes) runtimeTargetContext.initialRuntimeTargets;

  finalControlPlane = import ./final-control-plane.nix {
    inherit
      lib
      helpers
      common
      ipam
      resolveAccessAdvertisements
      resolvePolicyEndpointBindings
      resolveFirewallIntent
      sitePath
      siteAttrs
      attachments
      domains
      realizationIndex
      endpointInventoryIndex
      routedPrefixesByTenant
      dnsServiceRouteSpecs
      providerEndpointForServiceProvider
      providerTenantsForServiceProvider
      policyDerivedDnsAllowedClassesForListeners
      policyDerivedDnsForwardersForListeners
      policyDerivedDnsUpstreamRecordsForListeners
      normalizeRuntimeTargetRoutes
      normalizeRuntimeTargetRoutesAfterPolicyComplements
      normalizedRuntimeTargets
      ;
  };

in
finalControlPlane // {
  forwardingSemantics = siteAttrs.forwardingSemantics or { };
}
