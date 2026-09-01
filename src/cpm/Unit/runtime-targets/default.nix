{
  lib,
  helpers,
  common,
  realizationIndex,
  enterpriseName,
  siteName,
  sitePath,
  nodes,
  routingMode,
  bgpSiteAsn,
  bgpTopology,
  uplinkRouting,
  overlayProvisioning,
  siteOverlays,
  attachments,
  routedPrefixesByTenant,
  buildExplicitInterfaceEntry,
  buildSyntheticUplinkInterfaceEntry,
  buildInventoryOverlayRuntimeAdapterEntry,
  resolveRuntimeContainers,
  resolveRuntimeServices,
  bgpNetworksForNode,
  bgpNeighborsForNode,
  filterRoutesForBgp,
  routerRoleSet,
}:

let
  inherit (helpers)
    hasAttr
    isNonEmptyString
    logicalKey
    requireAttrs
    requireString
    sortedNames
    ;
  inherit (common)
    attrsOrEmpty
    failForwarding
    failInventory
    ipam
    ;

  validateSiteRouting =
    if routingMode == "bgp" then
      if !builtins.isInt bgpSiteAsn then
        failForwarding "forwardingModel.${enterpriseName}.${siteName}.routing.bgp.asn" "bgp mode requires integer 'asn'"
      else if bgpTopology != "policy-rr" then
        failForwarding "forwardingModel.${enterpriseName}.${siteName}.routing.bgp.topology" "only 'policy-rr' is supported right now"
      else
        true
    else
      true;

  buildRuntimeTarget = import ./build-target.nix {
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
      resolveRuntimeContainers
      resolveRuntimeServices
      bgpNetworksForNode
      bgpNeighborsForNode
      filterRoutesForBgp
      routerRoleSet
      ;
  };

in
{
  runtimeTargets = builtins.seq validateSiteRouting (
    builtins.listToAttrs (builtins.map buildRuntimeTarget (sortedNames nodes))
  );
}
