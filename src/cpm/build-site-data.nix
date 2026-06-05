{ lib, helpers, realizationIndex, endpointInventoryIndex, inventory ? { }, enterpriseRoot ? { } }:

{ enterpriseName, siteName, site }:

let
  inherit (helpers) isNonEmptyString sortedNames;

  ipam = import ./ipam.nix { inherit lib; };
  resolveAccessAdvertisements = import ./resolve-access-advertisements.nix { inherit helpers ipam; };
  resolveFirewallIntent = import ./resolve-firewall-intent.nix { inherit helpers; };
  resolvePolicyEndpointBindings = import ./resolve-policy-endpoint-bindings.nix { inherit helpers; };
  resolveRoutedPrefixes = import ./routed-prefixes.nix { inherit helpers; };

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
      pppoeEntries =
        builtins.concatLists (
          builtins.map
            (targetName:
              let
                target = runtimeTargets.${targetName};
                pppoe = (target.services or { }).pppoe or { };
              in
              (if pppoe ? client then [
                {
                  inherit targetName;
                  role = "client";
                  interface = pppoe.client.interface;
                }
              ] else [ ])
              ++ (if pppoe ? server then [
                {
                  inherit targetName;
                  role = "server";
                  interface = pppoe.server.interface;
                }
              ] else [ ]))
            (sortedNames runtimeTargets)
        );
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
          (targetName: ((runtimeTargets.${targetName}.services or { }).pppoe or { }) ? server)
          (sortedNames runtimeTargets);
      advertisementDisabled = entry: (entry.enabled or true) == false;
      validateServerFallbackSuppressed = targetName:
        let
          target = runtimeTargets.${targetName};
          advertisements = target.advertisements or { };
          dhcp4 = advertisements.dhcp4 or [ ];
          ipv6Ra = advertisements.ipv6Ra or [ ];
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

  routedClientGuaMode = import ./Site/build-data/routed-client-gua-mode.nix {
    inherit helpers common;
  } {
    inherit tenantPrefixOwners runtimeTargets;
  };

  overlayClientGuaMode = import ./Site/build-data/overlay-client-gua-mode.nix {
    inherit helpers common;
  } {
    inherit runtimeTargets;
  };

  emitOutput = import ./Site/build-data/output.nix;
in
if validatePPPoEContracts then
emitOutput {
  inherit lib accessAdvertisements attachments bgpSiteAsn bgpTopology communicationContract coreNodeNames domainsValue isNonEmptyString ipv6Plan overlayClientGuaMode overlayProvisioning policyAttrs policyEndpointBindings policyNodeName routedClientGuaMode routedPrefixesByTenant routingMode runtimeTargets siteAttrs siteDisplayName siteId tenantPrefixOwners trafficPaths transitAttrs uplinkCoreNames uplinkNames uplinkRouting upstreamSelectorNodeName forwardingSemantics;
  services = resolvedServices;
}
else
  throw "unreachable"
