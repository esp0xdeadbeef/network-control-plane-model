{ lib, helpers, realizationIndex, endpointInventoryIndex, inventory ? { }, enterpriseRoot ? { } }:

{ enterpriseName, siteName, site }:

let
  inherit (helpers) isNonEmptyString;

  resolveAccessAdvertisements = import ./resolve-access-advertisements.nix { inherit helpers; };
  resolveFirewallIntent = import ./resolve-firewall-intent.nix { inherit helpers; };
  resolvePolicyEndpointBindings = import ./resolve-policy-endpoint-bindings.nix { inherit helpers; };
  resolveRoutedPrefixes = import ./routed-prefixes.nix { inherit helpers; };
  ipam = import ./ipam.nix { inherit lib; };

  common = import ./Site/build-data/common.nix {
    inherit helpers ipam enterpriseRoot;
  };
  inherit (common) allSiteEntries;

  sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
  siteInput = import ./Site/build-data/input.nix {
    inherit helpers common inventory site sitePath;
  };
  inherit (siteInput)
    allowedRelations
    attachments
    communicationContract
    coreNodeNames
    domains
    domainsValue
    inventoryAttrs
    inventoryEndpoints
    links
    nodes
    ownership
    policyAttrs
    policyNodeName
    serviceDefinitions
    siteAttrs
    siteDisplayName
    siteId
    tenantPrefixOwners
    trafficPaths
    transitAttrs
    uplinkCoreNames
    uplinkNames
    upstreamSelectorNodeName
    ;

  dnsContext = import ./Site/build-data/dns-context.nix {
    inherit
      lib
      helpers
      common
      inventoryEndpoints
      sitePath
      domains
      attachments
      nodes
      ownership
      allowedRelations
      serviceDefinitions
      ;
  };
  inherit (dnsContext)
    dnsServiceRouteSpecs
    policyDerivedDnsAllowFromForListeners
    policyDerivedDnsAllowedClassesForListeners
    policyDerivedDnsAllowedClassesForTenants
    policyDerivedDnsDirectEgressBlockedForListeners
    policyDerivedDnsDirectEgressBlockedForTenants
    policyDerivedDnsForwardersForListeners
    policyDerivedDnsForwardersForTenants
    providerEndpointForServiceProvider
    providerTenantsForServiceProvider
    ;

  forwardingContext = import ./Site/build-data/forwarding-context.nix {
    inherit
      lib
      helpers
      common
      ipam
      sitePath
      siteAttrs
      inventoryAttrs
      domains
      uplinkNames
      resolveRoutedPrefixes
      enterpriseName
      siteName
      ;
  };
  inherit (forwardingContext)
    bgpSiteAsn
    bgpTopology
    ipv6Plan
    normalizeRuntimeTargetRoutes
    overlayNames
    overlayProvisioning
    overlayReachability
    routedPrefixesByTenant
    routingMode
    siteIpv6Cfg
    siteRouting
    siteTenantsCfg
    siteUplinksCfg
    uplinkRouting
    ;

  runtimePipeline = import ./Site/build-data/runtime-pipeline.nix {
    inherit
      lib
      helpers
      common
      ipam
      realizationIndex
      endpointInventoryIndex
      resolveAccessAdvertisements
      resolvePolicyEndpointBindings
      resolveFirewallIntent
      enterpriseName
      siteName
      sitePath
      siteAttrs
      transitAttrs
      allSiteEntries
      attachments
      domains
      links
      nodes
      policyNodeName
      routingMode
      bgpSiteAsn
      bgpTopology
      uplinkRouting
      overlayProvisioning
      overlayNames
      siteTenantsCfg
      siteIpv6Cfg
      routedPrefixesByTenant
      dnsServiceRouteSpecs
      providerEndpointForServiceProvider
      providerTenantsForServiceProvider
      policyDerivedDnsAllowFromForListeners
      policyDerivedDnsAllowedClassesForListeners
      policyDerivedDnsAllowedClassesForTenants
      policyDerivedDnsDirectEgressBlockedForListeners
      policyDerivedDnsDirectEgressBlockedForTenants
      policyDerivedDnsForwardersForListeners
      policyDerivedDnsForwardersForTenants
      normalizeRuntimeTargetRoutes
      ;
  };
  inherit (runtimePipeline)
    accessAdvertisements
    forwardingSemantics
    policyEndpointBindings
    resolvedServices
    runtimeTargets
    ;

  emitOutput = import ./Site/build-data/output.nix;
in
emitOutput {
  inherit lib accessAdvertisements attachments bgpSiteAsn bgpTopology communicationContract coreNodeNames domainsValue isNonEmptyString ipv6Plan overlayProvisioning policyAttrs policyEndpointBindings policyNodeName routedPrefixesByTenant routingMode runtimeTargets siteAttrs siteDisplayName siteId tenantPrefixOwners trafficPaths transitAttrs uplinkCoreNames uplinkNames uplinkRouting upstreamSelectorNodeName forwardingSemantics;
  services = resolvedServices;
}
