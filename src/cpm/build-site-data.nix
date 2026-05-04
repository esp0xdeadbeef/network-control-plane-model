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
    requireStringList
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

  routeHelpers = import ./ControlModule/route-helpers.nix { inherit lib helpers common; };
  inherit (routeHelpers)
    normalizeRuntimeTargetRoutes
    ;

  augmentDnsServiceRoutesForTarget = import ./ControlModule/route-augmentation/dns.nix {
    inherit lib helpers common ipam routeHelpers sitePath dnsServiceRouteSpecs;
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
      inherit sitePath;
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
              (
                augmentOverlayTransitEndpointRoutesForTarget
                  targetName
                  (augmentOverlayUnderlayEndpointRoutesForTarget
                    targetName
                    defaultReachability.runtimeTargets.${targetName})
              );
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
    inherit helpers;
  };
  runtimeTargets =
    finalizeRuntimeTargets {
      inherit accessAdvertisements firewallIntent;
      normalizedRuntimeTargets = normalizedRuntimeTargetsWithOverlayTransitEndpointRoutes;
    };

  resolvedServices =
    builtins.map
      (
        serviceName:
        let
          resolvedService = policyEndpointBindings.services.${serviceName};
          providerNames =
            if builtins.isList (resolvedService.providers or null) then
              requireStringList "${sitePath}.services.${serviceName}.providers" resolvedService.providers
            else
              [ ];
        in
        resolvedService
        // {
          name = serviceName;
          providerEndpoints = builtins.map providerEndpointForServiceProvider providerNames;
          providerTenants = uniqueStrings (
            lib.concatMap providerTenantsForServiceProvider providerNames
          );
        }
      )
      (sortedNames policyEndpointBindings.services);
in
{
  siteId = siteId;
  siteName = siteDisplayName;
  policyNodeName = policyNodeName;
  upstreamSelectorNodeName = upstreamSelectorNodeName;
  coreNodeNames = coreNodeNames;
  uplinkCoreNames = uplinkCoreNames;
  uplinkNames = uplinkNames;
  attachments = attachments;
  domains = domainsValue;
  tenantPrefixOwners = tenantPrefixOwners;
  transit = transitAttrs;
  routing =
    {
      mode = routingMode;
      uplinks = uplinkRouting;
    }
    // (
      if routingMode == "bgp" then
        {
          bgp = {
            asn = bgpSiteAsn;
            topology = bgpTopology;
          };
        }
      else
        { }
    );
  runtimeTargets = runtimeTargets;
  forwardingSemantics = defaultReachability.forwardingSemantics;
  overlays = overlayProvisioning;
  relations = policyEndpointBindings.relations;
  routedPrefixes = routedPrefixesByTenant;
  services = resolvedServices;
  policy =
    policyAttrs
    // {
      interfaceTags = policyEndpointBindings.interfaceTags;
      endpointBindings =
        builtins.removeAttrs policyEndpointBindings [ "interfaceTags" ];
    };
}
// (lib.optionalAttrs (ipv6Plan != null) { ipv6 = ipv6Plan; })
// (
  if builtins.isAttrs (siteAttrs.egressIntent or null) then
    {
      egressIntent = siteAttrs.egressIntent;
    }
  else
    { }
)
// (
  if communicationContract != null then
    {
      communicationContract = communicationContract;
    }
  else
    { }
)
// (
  if builtins.isAttrs (siteAttrs.addressPools or null) then
    {
      addressPools = siteAttrs.addressPools;
    }
  else
    { }
)
// (
  if builtins.isAttrs (siteAttrs.ownership or null) then
    {
      ownership = siteAttrs.ownership;
    }
  else
    { }
)
// (
  if builtins.isAttrs (siteAttrs.overlayReachability or null) then
    {
      overlayReachability = siteAttrs.overlayReachability;
    }
  else
    { }
)
// (
  if builtins.isAttrs (siteAttrs.topology or null) then
    {
      topology = siteAttrs.topology;
    }
  else
    { }
)
// (
  if isNonEmptyString (siteAttrs.enterprise or null) then
    {
      enterprise = siteAttrs.enterprise;
    }
  else
    { }
)
