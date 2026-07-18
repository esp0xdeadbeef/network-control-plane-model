{ lib
, accessAdvertisements
, accessSpaceDiscovery
, attachments
, bgpSiteAsn
, bgpTopology
, communicationContract
, coreNodeNames
, dnsContract
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
  runtimeDnsWarnings = lib.unique (
    lib.concatMap
      (
        target:
        let
          services = if builtins.isAttrs (target.services or null) then target.services else { };
          dns = if builtins.isAttrs (services.dns or null) then services.dns else { };
        in
        if builtins.isList (dns.reproducibilityWarnings or null) then
          dns.reproducibilityWarnings
        else
          [ ]
      )
      (builtins.attrValues runtimeTargets)
  );
  effectiveDnsContract = dnsContract // {
    warnings = lib.unique (
      (if builtins.isList (dnsContract.warnings or null) then dnsContract.warnings else [ ])
      ++ runtimeDnsWarnings
    );
  };

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

  # ── Emulation subnet conflict detection (NG2) ──
  # Per SMS-012 MR6/Seeded Negative 2: if an emulation subnet overlaps with an
  # existing tenant or transit subnet, emit diagnostic and exclude the conflicting
  # emulation subnet.
  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);

  ipv4ToInt = octets:
    builtins.elemAt octets 0 * 16777216
    + builtins.elemAt octets 1 * 65536
    + builtins.elemAt octets 2 * 256
    + builtins.elemAt octets 3;

  ipv4NetworkBaseInt = addrInt: prefixLen:
    let block = pow2 (32 - prefixLen);
    in (builtins.div addrInt block) * block;

  parseSubnetCidr = cidr:
    let
      parts = lib.splitString "/" cidr;
      addrStr = builtins.elemAt parts 0;
      prefix = lib.toInt (builtins.elemAt parts 1);
      octets = map lib.toInt (lib.splitString "." addrStr);
    in {
      addrInt = ipv4ToInt octets;
      inherit prefix;
    };

  # Check if two CIDR subnets overlap (one contains the other's network base).
  # Excludes identical CIDRs — dedupStrings already handles those.
  subnetOverlap = cidrA: cidrB:
    if cidrA == cidrB then false
    else
    let
      pa = parseSubnetCidr cidrA;
      pb = parseSubnetCidr cidrB;
      baseA = ipv4NetworkBaseInt pa.addrInt pa.prefix;
      baseB = ipv4NetworkBaseInt pb.addrInt pb.prefix;
      # Network base of B, normalized to A's prefix == A's base?
      containsA = ipv4NetworkBaseInt pb.addrInt pa.prefix == baseA;
      containsB = ipv4NetworkBaseInt pa.addrInt pb.prefix == baseB;
    in
    containsA || containsB;

  # Per-subnet conflict check against all modeled subnets (tenant + transit)
  modeledSubnets = tenantSubnets ++ transitSubnets;
  emulationSubnetConflictDiags =
    let
      checkSubnet = subnet:
        let
          conflicts = builtins.filter
            (modeled: subnetOverlap subnet modeled)
            modeledSubnets;
        in
        if conflicts == [ ] then null
        else {
          diagnostic = "emulation-subnet-conflicts-with-model";
          emulationSubnet = subnet;
          conflictingModeledSubnets = conflicts;
          severity = "HIGH";
          message = "Emulation subnet ${subnet} overlaps with modeled subnet(s): "
            + lib.concatStringsSep ", " conflicts;
        };
    in
    builtins.filter (x: x != null) (builtins.map checkSubnet guardedEmulationSubnets);

  # Exclude emulation subnets that conflict with modeled topology
  conflictingEmulationSubnets =
    builtins.map (d: d.emulationSubnet) emulationSubnetConflictDiags;

  conflictFilteredEmulationSubnets =
    builtins.filter
      (subnet: !(builtins.elem subnet conflictingEmulationSubnets))
      guardedEmulationSubnets;

  fabricSubnets = dedupStrings (tenantSubnets ++ transitSubnets ++ conflictFilteredEmulationSubnets);
  fabricSubnetSources = {
    tenantCount = builtins.length tenantSubnets;
    transitCount = builtins.length transitSubnets;
    emulationCount = builtins.length conflictFilteredEmulationSubnets;
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
  emulationSubnetConflict = {
    validated = emulationSubnetConflictDiags == [ ];
    diagnostics = emulationSubnetConflictDiags;
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
// (lib.optionalAttrs (dnsContract != { }) { dns = effectiveDnsContract; })
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
  if builtins.isAttrs (siteAttrs.prefixAuthority or null) then
    {
      prefixAuthority = siteAttrs.prefixAuthority;
    }
  else
    { }
)
// (
  if builtins.isAttrs (siteAttrs.trafficPathValidation or null) then
    {
      trafficPathValidation = siteAttrs.trafficPathValidation;
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
