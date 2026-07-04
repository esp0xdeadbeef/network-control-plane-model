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
  inherit (helpers) isNonEmptyString sortedNames;

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

  rawInitialRuntimeTargets = runtimeTargetBuilder.runtimeTargets;

  bridgeFromPort = port:
    if builtins.isAttrs (port.attach or null) && isNonEmptyString (port.attach.bridge or null) then
      port.attach.bridge
    else if isNonEmptyString (port.hostBridge or null) then
      port.hostBridge
    else
      null;

  targetLogicalName = target:
    let
      logical = target.logicalNode or null;
    in
    if builtins.isAttrs logical then
      logical.name or ""
    else if isNonEmptyString logical then
      logical
    else
      "";

  targetMatchesTenant = target: tenant:
    let
      logicalName = targetLogicalName target;
    in
    logicalName == "${siteName}-access-${tenant}"
    || lib.hasSuffix "-access-${tenant}" logicalName;

  fallbackTenantBridge = target: tenant:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      ifaces = attrsOrEmpty (effective.interfaces or null);
    in
    if ! targetMatchesTenant target tenant then
      null
    else
      builtins.foldl'
        (acc: ifName:
          if acc != null then acc
          else
            let
              port = attrsOrEmpty ifaces.${ifName};
            in
            bridgeFromPort port)
        null
        (sortedNames ifaces);

  enrichTenantInterface = target: iface:
    let
      sourceKind = iface.sourceKind or iface.kind or null;
      tenant = iface.tenant or null;
      existingAttach = iface.attach or null;
      bridge =
        if sourceKind == "tenant" && isNonEmptyString tenant
           && !(builtins.isAttrs existingAttach && isNonEmptyString (existingAttach.bridge or null))
        then
          fallbackTenantBridge target tenant
        else
          null;
    in
    if bridge == null then
      iface
    else
      iface // {
        attach = {
          kind = "bridge";
          bridge = bridge;
        };
      };

  enrichRuntimeTarget = _targetName: target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      ifaces = attrsOrEmpty (effective.interfaces or null);
    in
    if ifaces == { } then
      target
    else
      target // {
        effectiveRuntimeRealization =
          effective
          // {
            interfaces = builtins.mapAttrs (_ifName: iface: enrichTenantInterface target iface) ifaces;
          };
      };

  initialRuntimeTargets = builtins.mapAttrs enrichRuntimeTarget rawInitialRuntimeTargets;

in
{
  inherit initialRuntimeTargets;
}
