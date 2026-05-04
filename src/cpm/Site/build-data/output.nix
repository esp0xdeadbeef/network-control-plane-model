{
  lib,
  accessAdvertisements,
  attachments,
  bgpSiteAsn,
  bgpTopology,
  communicationContract,
  coreNodeNames,
  domainsValue,
  forwardingSemantics,
  ipv6Plan,
  isNonEmptyString,
  overlayProvisioning,
  policyAttrs,
  policyEndpointBindings,
  policyNodeName,
  routedPrefixesByTenant,
  routingMode,
  runtimeTargets,
  services,
  siteAttrs,
  siteDisplayName,
  siteId,
  tenantPrefixOwners,
  transitAttrs,
  uplinkCoreNames,
  uplinkNames,
  uplinkRouting,
  upstreamSelectorNodeName,
}:

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
  forwardingSemantics = forwardingSemantics;
  overlays = overlayProvisioning;
  relations = policyEndpointBindings.relations;
  routedPrefixes = routedPrefixesByTenant;
  services = services;
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
