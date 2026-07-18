{ lib
, helpers
, realizationIndex
, endpointInventoryIndex
, inventory ? { }
, enterpriseRoot ? { }
, ipam ? import ./ipam.nix { inherit lib; }
, common ? import ./Site/build-data/common.nix {
    inherit helpers ipam enterpriseRoot;
  }
, emulationSubnets ? [ ]
}:

{ enterpriseName, siteName, site }:

let
  inherit (helpers) isNonEmptyString sortedNames;

  resolveAccessAdvertisements = import ./resolve-access-advertisements.nix { inherit helpers ipam; };
  resolveFirewallIntent = import ./resolve-firewall-intent.nix { inherit helpers; };
  resolvePolicyEndpointBindings = import ./resolve-policy-endpoint-bindings.nix { inherit helpers; };
  resolveRoutedPrefixes = import ./routed-prefixes.nix { inherit helpers; };

  inherit (common) allSiteEntries;

  sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
  siteInput = import ./Site/build-data/input.nix {
    inherit helpers common inventory site sitePath;
  };
  inherit (siteInput)
    accessSpaceDiscovery
    allowedRelations
    attachments
    communicationContract
    coreNodeNames
    domains
    domainsValue
    dnsContract
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

  providerAccessDns = import ./Site/build-data/provider-access-dns.nix {
    inherit
      lib
      helpers
      common
      inventoryAttrs
      enterpriseName
      siteName
      siteId
      siteDisplayName
      serviceDefinitions
      ;
  };

  dnsContext = import ./Site/build-data/dns-context.nix {
    inherit
      lib
      helpers
      common
      providerAccessDns
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
    policyDerivedDnsDirectEgressBlockedTenants
    policyDerivedDnsDirectEgressBlockedForListeners
    policyDerivedDnsDirectEgressBlockedForTenants
    policyDerivedDnsForwardersForListeners
    policyDerivedDnsForwardersForTenants
    policyDerivedDnsUpstreamRecordsForListeners
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
      allSiteEntries
      attachments
      domains
      uplinkNames
      resolveRoutedPrefixes
      enterpriseName
      siteName
      ;
  };
  inherit (forwardingContext)
    addPolicyRoutingAllocationsToTarget
    bgpSiteAsn
    bgpTopology
    ipv6Plan
    normalizeRuntimeTargetRoutes
    normalizeRuntimeTargetRoutesAfterPolicyComplements
    normalizeRuntimeTargetRoutesWith
    overlayNames
    overlayProvisioning
    overlayReachability
    routedPrefixesByTenant
    routingMode
    siteControlPlaneCfg
    siteIpv6Cfg
    siteOverlays
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
      allowedRelations
      trafficPaths
      domains
      dnsContract
      inventoryEndpoints
      links
      nodes
      serviceDefinitions
      policyNodeName
      routingMode
      bgpSiteAsn
      bgpTopology
      uplinkRouting
      overlayProvisioning
      overlayNames
      siteOverlays
      siteTenantsCfg
      siteIpv6Cfg
      routedPrefixesByTenant
      tenantPrefixOwners
      dnsServiceRouteSpecs
      providerEndpointForServiceProvider
      providerTenantsForServiceProvider
      policyDerivedDnsAllowFromForListeners
      policyDerivedDnsAllowedClassesForListeners
      policyDerivedDnsAllowedClassesForTenants
      policyDerivedDnsDirectEgressBlockedTenants
      policyDerivedDnsDirectEgressBlockedForListeners
      policyDerivedDnsDirectEgressBlockedForTenants
      policyDerivedDnsForwardersForListeners
      policyDerivedDnsForwardersForTenants
      policyDerivedDnsUpstreamRecordsForListeners
      addPolicyRoutingAllocationsToTarget
      normalizeRuntimeTargetRoutes
      normalizeRuntimeTargetRoutesAfterPolicyComplements
      normalizeRuntimeTargetRoutesWith
      emulationSubnets
      ;
  };

  inherit (runtimePipeline)
    accessAdvertisements
    forwardingSemantics
    policyEndpointBindings
    resolvedServices
    runtimeTargets
    ;

  validatePolicyDsReturnPath =
    import ./Site/build-data/policy-ds-return-path-guard.nix {
      inherit lib common;
    } {
      inherit tenantPrefixOwners runtimeTargets;
    };

  pppoePairingFallbackRowId = "FS-800-HDS-010-SDS-020-SMS-030";

  validatePPPoEContracts =
    let
      siteTargetNames =
        builtins.filter
          (targetName:
            let
              logical = realizationIndex.targetDefs.${targetName}.logical;
            in
            logical.enterprise == enterpriseName && logical.site == siteName)
          (sortedNames realizationIndex.targetDefs);
      targetServices = targetName:
        realizationIndex.targetDefs.${targetName}.node.services or { };
      targetAdvertisements = targetName:
        realizationIndex.targetDefs.${targetName}.node.advertisements or { };
      pppoeService = targetName:
        (targetServices targetName).pppoe or null;
      pppoeTargetNames =
        builtins.filter
          (targetName: pppoeService targetName != null)
          siteTargetNames;
      normalizePPPoEEntry = targetName:
        let
          pppoePath = "${realizationIndex.targetDefs.${targetName}.nodePath}.services.pppoe";
          pppoe = common.attrsOrEmpty (pppoeService targetName);
          serviceNames = sortedNames pppoe;
          unexpectedServiceNames =
            builtins.filter (name: !(builtins.elem name [ "client" "server" ])) serviceNames;
          roleCount =
            (if pppoe ? client then 1 else 0)
            + (if pppoe ? server then 1 else 0);
          _unexpected =
            if unexpectedServiceNames != [ ] then
              common.failInventory pppoePath "${pppoePairingFallbackRowId}: must contain only 'client' or 'server' roles"
            else
              true;
          _roleCount =
            if roleCount == 1 then
              true
            else
              common.failInventory pppoePath "${pppoePairingFallbackRowId}: must define exactly one of 'client' or 'server'";
          role = if pppoe ? client then "client" else "server";
          service = pppoe.${role};
        in
        builtins.seq _unexpected (
          builtins.seq _roleCount {
            inherit targetName role;
            interface = service.interface;
          }
        );
      pppoeEntries =
        builtins.map normalizePPPoEEntry pppoeTargetNames;
      pppoeInterfaces =
        builtins.foldl'
          (acc: entry:
            if builtins.elem entry.interface acc then acc else acc ++ [ entry.interface ])
          [ ]
          pppoeEntries;
      entriesForInterface = interface:
        builtins.filter (entry: entry.interface == interface) pppoeEntries;
      roleEntriesForInterface = interface: role:
        builtins.filter (entry: entry.role == role) (entriesForInterface interface);
      validateInterfacePair = interface:
        let
          clientEntries = roleEntriesForInterface interface "client";
          serverEntries = roleEntriesForInterface interface "server";
        in
        if builtins.length clientEntries == 1 && builtins.length serverEntries == 1 then
          true
        else
          common.failInventory
            "realization.nodes.*.services.pppoe"
            "${pppoePairingFallbackRowId}: PPPoE interface '${interface}' requires exactly one client and one server before renderer handoff";
      pppoeServerTargets =
        builtins.filter
          (targetName: (common.attrsOrEmpty (pppoeService targetName)) ? server)
          pppoeTargetNames;
      advertisementDisabled = entry: (entry.enabled or true) == false;
      advertisementEntries = value:
        if builtins.isList value then
          value
        else if builtins.isAttrs value then
          builtins.attrValues value
        else
          [ ];
      validateServerFallbackSuppressed = targetName:
        let
          advertisements = targetAdvertisements targetName;
          dhcp4 = advertisementEntries (advertisements.dhcp4 or [ ]);
          ipv6Ra = advertisementEntries (advertisements.ipv6Ra or [ ]);
        in
        if dhcp4 != [ ] && ipv6Ra != [ ] && builtins.all advertisementDisabled dhcp4 && builtins.all advertisementDisabled ipv6Ra then
          true
        else
          common.failInventory
            "realization.nodes.${targetName}.advertisements"
            "${pppoePairingFallbackRowId}: PPPoE server targets must explicitly disable DHCP4 and IPv6 RA/SLAAC fallback before renderer handoff";
    in
    builtins.deepSeq
      (
        (builtins.map validateInterfacePair pppoeInterfaces)
        ++ (builtins.map validateServerFallbackSuppressed pppoeServerTargets)
      )
      true;

  routedClientGuaMode = import ./Site/build-data/routed-client-gua-mode.nix
    {
      inherit helpers common;
    }
    {
      inherit tenantPrefixOwners runtimeTargets;
    };

  ipv4InternetMode = import ./Site/build-data/ipv4-internet-mode.nix
    {
      inherit helpers common;
    }
    {
      inherit tenantPrefixOwners runtimeTargets;
    };

  overlayClientGuaMode = import ./Site/build-data/overlay-client-gua-mode.nix
    {
      inherit helpers common;
    }
    {
      inherit runtimeTargets;
    };

  ulaNat66Mode = import ./Site/build-data/ula-nat66-mode.nix
    {
      inherit helpers common;
    }
    {
      inherit tenantPrefixOwners runtimeTargets;
    };

  endpointAssignmentModule = import ./Site/build-data/endpoint-assignment.nix {
    inherit lib helpers common enterpriseName siteName;
    ownership = siteAttrs.ownership or { };
    inventoryEndpoints = inventoryEndpoints;
    runtimeTargets = runtimeTargets;
  };
  inherit (endpointAssignmentModule) endpointAssignment;

  endpointAssignmentChecker = import ./Site/check/endpoint-assignment-checker.nix {
    inherit helpers common;
  };

  validateEndpointAssignments =
    endpointAssignmentChecker {
      inherit endpointAssignment;
    };

  rendererContracts = import ./Site/build-data/renderer-contracts.nix {
    inherit
      lib
      accessSpaceDiscovery
      helpers
      common
      communicationContract
      enterpriseName
      forwardingSemantics
      overlayProvisioning
      policyAttrs
      policyEndpointBindings
      routedPrefixesByTenant
      routingMode
      runtimeTargets
      siteControlPlaneCfg
      siteDisplayName
      siteId
      siteName
      tenantPrefixOwners
      trafficPaths
      ;
    services = resolvedServices;
  };

  emitOutput = import ./Site/build-data/output.nix;
in
if validatePPPoEContracts then
  builtins.deepSeq
    validateEndpointAssignments.diagnostics
    (builtins.deepSeq
      validatePolicyDsReturnPath
      (emitOutput
      {
        inherit lib accessAdvertisements emulationSubnets accessSpaceDiscovery attachments bgpSiteAsn bgpTopology communicationContract coreNodeNames dnsContract domainsValue endpointAssignment isNonEmptyString ipv4InternetMode ipv6Plan overlayClientGuaMode overlayProvisioning policyAttrs policyEndpointBindings policyNodeName rendererContracts routedClientGuaMode routedPrefixesByTenant routingMode runtimeTargets siteAttrs siteDisplayName siteId tenantPrefixOwners trafficPaths transitAttrs uplinkCoreNames uplinkNames uplinkRouting upstreamSelectorNodeName forwardingSemantics ulaNat66Mode;
        services = resolvedServices;
        endpointAssignmentCheckDiagnostics = validateEndpointAssignments.diagnostics;
      }))
else
  throw "unreachable"
