{ lib, helpers, realizationIndex, endpointInventoryIndex, inventory ? { }, enterpriseRoot ? { } }:

{ enterpriseName, siteName, site }:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    isNonEmptyString
    logicalKey
    requireAttrs
    requireList
    requireRoutes
    requireString
    sortedNames
    ;

  deriveDefaultReachability =
    import ./default-reachability-model.nix {
      inherit helpers;
    };

  resolveAccessAdvertisements =
    import ./resolve-access-advertisements.nix {
      inherit helpers;
    };

  resolveFirewallIntent =
    import ./resolve-firewall-intent.nix {
      inherit helpers;
    };

  resolvePolicyEndpointBindings =
    import ./resolve-policy-endpoint-bindings.nix {
      inherit helpers;
    };

  resolveRoutedPrefixes =
    import ./routed-prefixes.nix {
      inherit helpers;
    };

  ipam =
    import ./ipam.nix {
      inherit lib;
    };

  common = import ./Site/build-data/common.nix {
    inherit helpers ipam enterpriseRoot;
  };
  inherit (common)
    allSiteEntries
    attrsOrEmpty
    cidrContainsAddress
    failForwarding
    failInventory
    listOrEmpty
    mergeRoutes
    uniqueStrings
    ;

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
    transitAttrs
    uplinkCoreNames
    uplinkNames
    upstreamSelectorNodeName
    ;

  dnsPolicy = import ./ControlModule/dns-policy {
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
  inherit (dnsPolicy)
    providerEndpointForServiceProvider
    providerTenantsForServiceProvider
    ;
  dnsPolicyDerived = import ./ControlModule/dns-policy/derived-services.nix {
    inherit lib helpers dnsPolicy sitePath allowedRelations serviceDefinitions;
  };
  inherit (dnsPolicyDerived)
    dnsServiceRouteSpecs
    policyDerivedDnsAllowFromForListeners
    policyDerivedDnsAllowedClassesForListeners
    policyDerivedDnsAllowedClassesForTenants
    policyDerivedDnsForwardersForTenants
    ;

  controlPlane = import ./Site/build-data/control-plane.nix {
    inherit helpers common inventoryAttrs enterpriseName siteName uplinkNames;
  };
  inherit (controlPlane)
    bgpSiteAsn
    bgpTopology
    routingMode
    siteControlPlaneCfg
    siteIpv6Cfg
    siteOverlays
    siteRouting
    siteTenantsCfg
    siteUplinksCfg
    uplinkRouting
    ;

  overlayData = import ./Site/build-data/overlay-provisioning.nix {
    inherit lib helpers common ipam siteAttrs siteOverlays sitePath;
  };
  inherit (overlayData)
    overlayNames
    overlayProvisioning
    overlayReachability
    ;

  overlayTransit = import ./ControlModule/overlay-transit/context.nix {
    inherit lib helpers common allSiteEntries sitePath overlayNames overlayProvisioning;
  };
  inherit (overlayTransit)
    overlayTransitEndpointAddressesByOverlay
    ;

  routeHelpers = import ./ControlModule/route-helpers.nix { inherit lib helpers common ipam; };
  inherit (routeHelpers)
    normalizeRuntimeTargetRoutes
    ;

  augmentDnsServiceRoutesForTarget = import ./ControlModule/route-augmentation/dns.nix {
    inherit lib helpers common ipam routeHelpers sitePath dnsServiceRouteSpecs;
  };

  augmentServiceIngressRoutesForTarget = import ./ControlModule/route-augmentation/service-ingress.nix {
    inherit
      lib
      helpers
      common
      ipam
      routeHelpers
      sitePath
      allowedRelations
      serviceDefinitions
      providerEndpointForServiceProvider
      ;
  };

  augmentOverlayTransitEndpointRoutesForTarget = import ./ControlModule/route-augmentation/overlay-transit.nix {
    inherit helpers common routeHelpers sitePath overlayNames overlayTransitEndpointAddressesByOverlay;
  };

  augmentOverlayUnderlayEndpointRoutesForTarget = import ./ControlModule/route-augmentation/overlay-underlay.nix {
    inherit common helpers routeHelpers overlayTransitEndpointAddressesByOverlay;
    siteOverlayNameSet = builtins.listToAttrs (map (name: { inherit name; value = true; }) overlayNames);
  };

  ipv6Data = import ./Site/build-data/ipv6-plan.nix {
    inherit
      helpers
      common
      resolveRoutedPrefixes
      enterpriseName
      siteName
      sitePath
      domains
      siteTenantsCfg
      siteIpv6Cfg
      uplinkNames
      ;
  };
  inherit (ipv6Data)
    ipv6Plan
    routedPrefixesByTenant
    ;

  backingRefResolver = import ./Unit/runtime-targets/interfaces/backing-ref.nix {
    inherit lib helpers common enterpriseName siteName sitePath attachments links;
  };
  inherit (backingRefResolver)
    resolveBackingRef
    ;

  hostUplinkValidator = import ./Unit/runtime-targets/interfaces/host-uplink.nix {
    inherit helpers common;
  };
  inherit (hostUplinkValidator)
    requireExplicitHostUplinkAddressing
    ;

  buildExplicitInterfaceEntry = import ./Unit/runtime-targets/interfaces/explicit.nix {
    inherit helpers common sitePath overlayProvisioning resolveBackingRef requireExplicitHostUplinkAddressing;
  };

  buildSyntheticUplinkInterfaceEntry = import ./Unit/runtime-targets/interfaces/synthetic-uplink.nix {
    inherit helpers common sitePath enterpriseName siteName overlayNames requireExplicitHostUplinkAddressing;
  };

  runtimeServices = import ./Unit/runtime-services {
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
      policyDerivedDnsForwardersForTenants
      uniqueStrings
      ;
  };
  inherit (runtimeServices)
    resolveRuntimeServices
    tenantAttachmentsForNode
    ;

  runtimeContainers = import ./Unit/runtime-targets/containers.nix {
    inherit helpers common sitePath;
  };
  inherit (runtimeContainers)
    resolveRuntimeContainers
    ;

  runtimeBgp = import ./Unit/runtime-targets/bgp.nix {
    inherit lib helpers common sitePath nodes policyNodeName bgpSiteAsn;
  };
  inherit (runtimeBgp)
    bgpNetworksForNode
    bgpNeighborsForNode
    filterRoutesForBgp
    routerRoleSet
    ;

  runtimeTargetBuilder = import ./Unit/runtime-targets {
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
      buildExplicitInterfaceEntry
      buildSyntheticUplinkInterfaceEntry
      resolveRuntimeContainers
      resolveRuntimeServices
      bgpNetworksForNode
      bgpNeighborsForNode
      filterRoutesForBgp
      routerRoleSet
      ;
  };
  initialRuntimeTargets = runtimeTargetBuilder.runtimeTargets;

  siteAttrsForDefaultReachability =
    siteAttrs
    // {
      tenants = siteTenantsCfg;
      ipv6 = siteIpv6Cfg;
    };

  defaultReachability =
    deriveDefaultReachability {
      inherit sitePath allSiteEntries;
      siteAttrs = siteAttrsForDefaultReachability;
      transit = transitAttrs;
      runtimeTargets = initialRuntimeTargets;
    };

  runtimeTargetsWithOverlayTransitEndpointRoutes =
    builtins.listToAttrs (
      builtins.map
        (targetName: {
          name = targetName;
          value =
            augmentDnsServiceRoutesForTarget
              targetName
              (augmentServiceIngressRoutesForTarget
                targetName
                (augmentOverlayTransitEndpointRoutesForTarget
                  targetName
                  (augmentOverlayUnderlayEndpointRoutesForTarget
                    targetName
                    defaultReachability.runtimeTargets.${targetName})));
        })
        (sortedNames defaultReachability.runtimeTargets)
    );

  normalizedRuntimeTargetsWithOverlayTransitEndpointRoutes =
    builtins.mapAttrs (_targetName: normalizeRuntimeTargetRoutes) runtimeTargetsWithOverlayTransitEndpointRoutes;

  accessAdvertisements =
    resolveAccessAdvertisements {
      inherit sitePath siteAttrs realizationIndex endpointInventoryIndex routedPrefixesByTenant;
      runtimeTargets = normalizedRuntimeTargetsWithOverlayTransitEndpointRoutes;
    };

  firewallIntent =
    resolveFirewallIntent {
      inherit sitePath siteAttrs;
      runtimeTargets = normalizedRuntimeTargetsWithOverlayTransitEndpointRoutes;
    };

  policyEndpointBindings =
    resolvePolicyEndpointBindings {
      inherit sitePath siteAttrs attachments domains;
      runtimeTargets = normalizedRuntimeTargetsWithOverlayTransitEndpointRoutes;
    };

  finalizeRuntimeTargets = import ./ControlModule/runtime-targets/finalize.nix {
    inherit lib helpers common ipam;
  };
  runtimeTargets =
    finalizeRuntimeTargets {
      inherit accessAdvertisements firewallIntent;
      normalizedRuntimeTargets = normalizedRuntimeTargetsWithOverlayTransitEndpointRoutes;
    };

  dnsServiceUplinks = import ./ControlModule/dns-policy/service-uplinks.nix {
    inherit lib uniqueStrings dnsServiceRouteSpecs;
  };
  inherit (dnsServiceUplinks)
    preferredDnsUplinksByRelationForService
    preferredDnsUplinksForService
    ;

  resolvedServices = import ./Site/build-data/services.nix {
    inherit
      lib
      helpers
      uniqueStrings
      policyEndpointBindings
      providerEndpointForServiceProvider
      providerTenantsForServiceProvider
      preferredDnsUplinksByRelationForService
      preferredDnsUplinksForService
      sitePath
      ;
  };
in
import ./Site/build-data/output.nix {
  inherit
    lib
    accessAdvertisements
    attachments
    bgpSiteAsn
    bgpTopology
    communicationContract
    coreNodeNames
    domainsValue
    isNonEmptyString
    ipv6Plan
    overlayProvisioning
    policyAttrs
    policyEndpointBindings
    policyNodeName
    routedPrefixesByTenant
    routingMode
    runtimeTargets
    siteAttrs
    siteDisplayName
    siteId
    tenantPrefixOwners
    transitAttrs
    uplinkCoreNames
    uplinkNames
    uplinkRouting
    upstreamSelectorNodeName
    ;
  forwardingSemantics = defaultReachability.forwardingSemantics;
  services = resolvedServices;
}
