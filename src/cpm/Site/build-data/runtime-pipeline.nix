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
, allowedRelations
, trafficPaths
, domains
, dnsContract
, inventoryEndpoints
, links
, nodes
, serviceDefinitions
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
, tenantPrefixOwners
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
, addPolicyRoutingAllocationsToTarget
, normalizeRuntimeTargetRoutes
, normalizeRuntimeTargetRoutesAfterPolicyComplements
, normalizeRuntimeTargetRoutesWith
, enterpriseName
, siteName
, emulationSubnets ? [ ]
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

  bindNamedDnsServices = import ../../ControlModule/runtime-targets/named-dns-binding.nix {
    inherit
      lib
      common
      enterpriseName
      siteName
      sitePath
      allowedRelations
      serviceDefinitions
      inventoryEndpoints
      ;
    siteDns = dnsContract;
  };

  initialRuntimeTargetsWithPolicyRoutingAllocations =
    builtins.mapAttrs
      (_targetName: addPolicyRoutingAllocationsToTarget)
      runtimeTargetContext.initialRuntimeTargets;

  dnsBoundInitialRuntimeTargets = bindNamedDnsServices initialRuntimeTargetsWithPolicyRoutingAllocations;

  bindLocalDnsSharing = import ../../ControlModule/runtime-targets/local-dns-sharing.nix {
    inherit
      lib
      common
      enterpriseName
      siteName
      sitePath
      allowedRelations
      serviceDefinitions
      inventoryEndpoints
      ;
    siteDns = dnsContract;
  };

  dnsBoundRuntimeTargets = bindLocalDnsSharing dnsBoundInitialRuntimeTargets;

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
      (builtins.attrValues dnsBoundRuntimeTargets)
    )
  );

  normalizeRuntimeTargetRoutesWithGlobal =
    normalizeRuntimeTargetRoutesWith { inherit globalAddr4Access; };

  normalizedRuntimeTargets =
    builtins.mapAttrs (_targetName: normalizeRuntimeTargetRoutesWithGlobal) dnsBoundRuntimeTargets;

  addRelationPolicyRouting = import ../../ControlModule/runtime-targets/relation-policy-routing.nix {
    inherit
      lib
      common
      ipam
      sitePath
      tenantPrefixOwners
      allowedRelations
      trafficPaths
      serviceDefinitions
      providerTenantsForServiceProvider
      policyNodeName
      ;
  };

  relationPolicyRuntimeTargets = addRelationPolicyRouting normalizedRuntimeTargets;

  bindAccessRaPathMtu = import ../../ControlModule/runtime-targets/access-ra-path-mtu.nix {
    inherit lib;
  };
  pathMtuBoundRuntimeTargets = bindAccessRaPathMtu relationPolicyRuntimeTargets;

  scopeCoreDnsLanes = import ../../ControlModule/runtime-targets/core-dns-lane-scope.nix {
    inherit lib common;
  };
  laneScopedRuntimeTargets = scopeCoreDnsLanes pathMtuBoundRuntimeTargets;

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
      emulationSubnets
      ;
    normalizedRuntimeTargets = laneScopedRuntimeTargets;
  };

in
finalControlPlane // {
  forwardingSemantics = siteAttrs.forwardingSemantics or { };
}
