{ lib
, accessAdvertisements
, accessSpaceDiscovery
, attachments
, bgpSiteAsn
, bgpTopology
, communicationContract
, coreNodeNames
, domainsValue
, endpointAssignment
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
, endpointAssignmentCheckDiagnostics ? [ ]
, emulationSubnets ? [ ]
, emulationSubnetGuards ? { }
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

  # --- hostNat extraction ---
  coreNatIntents =
    builtins.filter
      (targetName:
        let
          t = runtimeTargets.${targetName} or { };
        in
        (t.role or "") == "core" && builtins.isAttrs (t.natIntent or null))
      (builtins.attrNames runtimeTargets);

  hostNat =
    if coreNatIntents != [ ] then
      (runtimeTargets.${builtins.head coreNatIntents}.natIntent or { }).hostNat or { }
    else
      { };

  # --- fabricSubnets enumeration ---
  # Deduplicate a list of strings
  dedupStrings = lst:
    builtins.attrNames (
      builtins.listToAttrs (
        builtins.map (s: { name = s; value = true; }) (
          builtins.filter isNonEmptyString lst
        )
      )
    );

  tenantSubnets =
    builtins.concatMap
      (tenant:
        if builtins.isAttrs tenant then
          let
            ipv4 = tenant.ipv4 or "";
          in
          if isNonEmptyString ipv4 then [ ipv4 ] else [ ]
        else if isNonEmptyString tenant then
          [ tenant ]
        else
          [ ])
      (builtins.attrValues (if builtins.isAttrs (domainsValue.tenants or null) then domainsValue.tenants else { })
        ++ (if builtins.isList (domainsValue.tenants or null) then domainsValue.tenants else [ ]));

  transitSubnets =
    let
      t = if transitAttrs != null then transitAttrs else { };
      adjacencies = if builtins.isList (t.adjacencies or null) then t.adjacencies else [ ];
    in
    dedupStrings (
      builtins.concatMap
        (adj:
          let
            endpoints = if builtins.isList (adj.endpoints or null) then adj.endpoints else [ ];
          in
          builtins.concatMap
            (ep:
              let
                addr4 = if builtins.isAttrs ep then ep.local.ipv4 or "" else "";
              in
              if isNonEmptyString addr4 then [ addr4 ] else [ ])
            endpoints)
        adjacencies);

  # ── Emulation subnet non-production guard validation ──
  # Per SMS-012: each emulation subnet must have an explicit non-production
  # guard (hatOnly or labScope). Subnets without guards are excluded from
  # fabricSubnets and a CRITICAL diagnostic is emitted.
  emulationSubnetGuardDiags =
    let
      subnetGuard = subnet:
        let
          guard = emulationSubnetGuards.${subnet} or { };
          hatOnly = guard.hatOnly or false;
          labScope = guard.labScope or "";
        in
        if hatOnly || labScope != "" then null
        else {
          diagnostic = "emulation-subnet-missing-production-guard";
          subnet = subnet;
          severity = "CRITICAL";
          message = "Emulation subnet ${subnet} declared without non-production guard (hatOnly or labScope required)";
        };
    in
    builtins.filter (x: x != null) (builtins.map subnetGuard emulationSubnets);
  # Only include guarded emulation subnets in fabric route set.
  guardedEmulationSubnets =
    builtins.filter
      (subnet:
        let
          guard = emulationSubnetGuards.${subnet} or { };
          hatOnly = guard.hatOnly or false;
          labScope = guard.labScope or "";
        in
        hatOnly || labScope != "")
      emulationSubnets;

  fabricSubnets = dedupStrings (tenantSubnets ++ transitSubnets ++ guardedEmulationSubnets);
  fabricSubnetSources = {
    tenantCount = builtins.length tenantSubnets;
    transitCount = builtins.length transitSubnets;
    emulationCount = builtins.length guardedEmulationSubnets;
  };

  # ── Emulation provenance tag verification ──
  # Per SMS-012: every route generated from an emulation subnet must carry
  # emulationSubnet = true provenance tag. Scan all runtime target P2P interfaces
  # for emulation-derived routes missing the tag.
  emulationProvenanceDiags =
    let
      allTargets = builtins.attrNames runtimeTargets;
      collectRoutes = acc: targetName:
        let
          target = runtimeTargets.${targetName} or { };
          interfaces = (target.effectiveRuntimeRealization or { }).interfaces or { };
          scanInterface = ifAcc: ifName:
            let
              iface = interfaces.${ifName} or { };
              routes = iface.routes or { };
              ipv4Routes = routes.ipv4 or [ ];
              emulationRoutes = builtins.filter (r: (r.proto or "") == "emulation") ipv4Routes;
            in
            ifAcc ++ emulationRoutes;
        in
        builtins.foldl' scanInterface acc (builtins.attrNames interfaces);
      allRoutes = builtins.foldl' collectRoutes [ ] allTargets;
      untaggedRoutes = builtins.filter (r: !(r.emulationSubnet or false)) allRoutes;
    in
    builtins.map
      (r: {
        diagnostic = "emulation-subnet-untagged-artifact";
        dst = r.dst or "unknown";
        severity = "MEDIUM";
        message = "Emulation-derived route to ${r.dst or "unknown"} missing provenance tag (emulationSubnet = true required)";
      })
      untaggedRoutes;
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
  inherit hostNat fabricSubnets fabricSubnetSources endpointAssignment;
  endpointAssignmentCheck = {
    validated = endpointAssignmentCheckDiagnostics == [ ];
    diagnostics = endpointAssignmentCheckDiagnostics;
  };
  emulationSubnetGuard = {
    validated = emulationSubnetGuardDiags == [ ];
    diagnostics = emulationSubnetGuardDiags;
  };
  emulationProvenance = {
    validated = emulationProvenanceDiags == [ ];
    diagnostics = emulationProvenanceDiags;
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
