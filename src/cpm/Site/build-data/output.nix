{ lib
, accessAdvertisements
, accessSpaceDiscovery
, attachments
, bgpSiteAsn
, bgpTopology
, communicationContract
, coreNodeNames
, domainsValue
, forwardingSemantics
, ipv4InternetMode
, ipv6Plan
, isNonEmptyString
, overlayClientGuaMode
, overlayProvisioning
, policyAttrs
, policyEndpointBindings
, policyNodeName
, rendererContracts
, routedClientGuaMode
, routedPrefixesByTenant
, routingMode
, runtimeTargets
, services
, siteAttrs
, siteDisplayName
, siteId
, tenantPrefixOwners
, trafficPaths
, transitAttrs
, uplinkCoreNames
, uplinkNames
, uplinkRouting
, upstreamSelectorNodeName
, ulaNat66Mode
,
}:

let
  ipv4ModeRecords =
    lib.filterAttrs (_name: records: records != [ ]) (ipv4InternetMode.records or { });

  ipv4ModeDiagnostics =
    lib.filterAttrs (_name: diagnostics: diagnostics != [ ]) (ipv4InternetMode.diagnostics or { });

  ipv4Output =
    (
      if ipv4ModeRecords == { } then
        { }
      else
        { internetModes = ipv4ModeRecords; }
    )
    // (
      if ipv4ModeDiagnostics == { } then
        { }
      else
        { diagnostics = ipv4ModeDiagnostics; }
    );

  routedClientGuaPayload =
    if routedClientGuaMode.records == [ ] && routedClientGuaMode.diagnostics == [ ] then
      { }
    else
      {
        internetModes = {
          routedClientGua = routedClientGuaMode.records;
        };
        diagnostics = {
          routedClientGua = routedClientGuaMode.diagnostics;
        };
      };

  overlayClientGuaPayload =
    if overlayClientGuaMode.records == [ ] && overlayClientGuaMode.diagnostics == [ ] then
      { }
    else
      {
        internetModes = {
          overlayClientGua = overlayClientGuaMode.records;
        };
        diagnostics = {
          overlayClientGua = overlayClientGuaMode.diagnostics;
        };
      };

  ulaNat66Payload =
    if ulaNat66Mode.records.ulaNat66 == [ ] && ulaNat66Mode.diagnostics.ulaNat66 == [ ] then
      { }
    else
      {
        internetModes = {
          ulaNat66 = ulaNat66Mode.records.ulaNat66;
        };
        diagnostics = {
          ulaNat66 = ulaNat66Mode.diagnostics.ulaNat66;
        };
      };

  ipv6Output =
    lib.recursiveUpdate
      (lib.recursiveUpdate
        (if ipv6Plan != null then ipv6Plan else { })
        (lib.recursiveUpdate routedClientGuaPayload overlayClientGuaPayload))
      ulaNat66Payload;
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
  trafficPaths = trafficPaths;
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
  rendererContracts = rendererContracts;
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
// (
  if accessSpaceDiscovery != null then
    {
      accessSpaceDiscovery = accessSpaceDiscovery;
    }
  else
    { }
)
// (lib.optionalAttrs (ipv4Output != { }) { ipv4 = ipv4Output; })
// (lib.optionalAttrs (ipv6Output != { }) { ipv6 = ipv6Output; })
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
