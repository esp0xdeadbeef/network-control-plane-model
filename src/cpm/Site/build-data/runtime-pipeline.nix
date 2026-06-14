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
, normalizeRuntimeTargetRoutesWith
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

  # Compute global {addr4 -> laneAccess} map across all targets.
  # Used to filter cross-lane complements: only complement source routes
  # whose dst belongs to the same access node as the current interface.
  globalAddr4Access = builtins.listToAttrs (
    builtins.concatLists (builtins.map
      (target:
        let
          ifaces = common.attrsOrEmpty ((common.attrsOrEmpty (target.effectiveRuntimeRealization or { })).interfaces or { });
        in
        builtins.concatLists (builtins.map
          (ifName:
            let
              iface = ifaces.${ifName} or { };
              addr4 = iface.addr4 or null;
              access = (common.attrsOrEmpty ((common.attrsOrEmpty (iface.backingRef or { })).lane or { })).access or null;
            in
            if addr4 != null && access != null then
              [ { name = addr4; value = access; } ]
            else [ ]
          )
          (builtins.attrNames ifaces)
        )
      )
      (builtins.attrValues runtimeTargetContext.initialRuntimeTargets)
    )
  );

  normalizeRuntimeTargetRoutesWithGlobal =
    normalizeRuntimeTargetRoutesWith { inherit globalAddr4Access; };

  normalizedRuntimeTargets =
    builtins.mapAttrs (_targetName: normalizeRuntimeTargetRoutesWithGlobal) runtimeTargetContext.initialRuntimeTargets;

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
