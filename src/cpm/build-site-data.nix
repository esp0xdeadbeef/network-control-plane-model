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
,
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
    policyDerivedDnsDirectEgressBlockedTenants
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
    bgpSiteAsn
    bgpTopology
    ipv6Plan
    normalizeRuntimeTargetRoutes
    overlayNames
    overlayProvisioning
    overlayReachability
    routedPrefixesByTenant
    routingMode
    siteControlPlaneCfg
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
      policyDerivedDnsDirectEgressBlockedTenants
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
              common.failInventory pppoePath "must contain only 'client' or 'server' roles"
            else
              true;
          _roleCount =
            if roleCount == 1 then
              true
            else
              common.failInventory pppoePath "must define exactly one of 'client' or 'server'";
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
            "PPPoE interface '${interface}' requires exactly one client and one server before renderer handoff";
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
            "PPPoE server targets must explicitly disable DHCP4 and IPv6 RA/SLAAC fallback before renderer handoff";
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

  rendererContracts = import ./Site/build-data/renderer-contracts.nix {
    inherit
      lib
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
  emitOutput
  {
    inherit lib accessAdvertisements attachments bgpSiteAsn bgpTopology communicationContract coreNodeNames domainsValue isNonEmptyString ipv4InternetMode ipv6Plan overlayClientGuaMode overlayProvisioning policyAttrs policyEndpointBindings policyNodeName rendererContracts routedClientGuaMode routedPrefixesByTenant routingMode runtimeTargets siteAttrs siteDisplayName siteId tenantPrefixOwners trafficPaths transitAttrs uplinkCoreNames uplinkNames uplinkRouting upstreamSelectorNodeName forwardingSemantics;
    services = resolvedServices;
  }
else
  throw "unreachable"
