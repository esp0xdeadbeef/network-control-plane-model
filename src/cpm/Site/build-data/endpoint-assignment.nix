# FS-720-HDS-010-SDS-025-SMS-010: endpointAssignment contract
#
# This module consumes endpoint definitions from intent (ownership.endpoints)
# and endpoint addresses from inventory, derives assignment modes, and emits
# structured endpointAssignment records for downstream renderer consumption.
#
# P2: DHCP records carry served prefix, gateway, pool, reservation binding,
#     namespace owner, assignment mode, and conflict behavior.
# P3: Static records carry address, prefix length, gateway, tenant/access
#     space, address family, and owning substrate.
# P7: Fail when DHCP fixture exists but CPM lacks required fields.
#
# CPM stance: Missing realization data is an error, not a defaulting opportunity.
{ lib
, helpers
, common
, ownership ? { }
, inventoryEndpoints ? { }
, runtimeTargets ? { }
, enterpriseName
, siteName
}:

let
  inherit (helpers)
    hasAttr
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    sortedNames
    ;
  inherit (common) attrsOrEmpty failInventory;

  gampRowId = "FS-720-HDS-010-SDS-025-SMS-010";
  gampBoundaryId = "FS-983";

  # ---------------------------------------------------------------
  # Tenant prefix index: ownership.prefixes keyed by tenant name
  # ---------------------------------------------------------------
  ownershipAttrs = attrsOrEmpty ownership;
  rawPrefixes = ownershipAttrs.prefixes or [ ];
  prefixesList =
    if builtins.isList rawPrefixes then rawPrefixes
    else builtins.attrValues rawPrefixes;

  tenantPrefixIndex =
    builtins.listToAttrs (
      builtins.map
        (prefix:
          let
            name = requireString
              "${gampRowId}: ownership.prefixes: missing name"
              (prefix.name or null);
          in
          { inherit name; value = prefix; })
        (builtins.filter (prefix: (prefix.kind or "") == "tenant") prefixesList));

  # ---------------------------------------------------------------
  # Endpoint definitions from intent
  # ---------------------------------------------------------------
  rawEndpoints = ownershipAttrs.endpoints or [ ];
  siteEndpoints =
    if builtins.isList rawEndpoints then rawEndpoints
    else builtins.attrValues rawEndpoints;

  # Valid endpoint: kind == "host" and has tenant
  validEndpoint = endpoint:
    let
      kind = endpoint.kind or "";
      tenant = endpoint.tenant or "";
    in
    kind == "host" && isNonEmptyString tenant;

  hostEndpoints = builtins.filter validEndpoint siteEndpoints;

  # ---------------------------------------------------------------
  # Helper: strip CIDR to get address or prefix
  # ---------------------------------------------------------------
  stripCidr = cidr:
    let parts = lib.splitString "/" cidr;
    in if builtins.length parts >= 1 then builtins.elemAt parts 0 else "";

  prefixLen = cidr:
    let parts = lib.splitString "/" cidr;
    in if builtins.length parts >= 2 then
      let plen = builtins.elemAt parts 1;
      in lib.toInt (if plen == "" then "0" else plen)
    else null;

  # ---------------------------------------------------------------
  # Tenant prefix lookup
  # ---------------------------------------------------------------
  tenantPrefix = tenant:
    if hasAttr tenant tenantPrefixIndex then
      tenantPrefixIndex.${tenant}
    else
      failInventory "ownership.prefixes"
        "${gampRowId}: no tenant prefix found for '${tenant}'";

  # ---------------------------------------------------------------
  # Derive assignment mode from available data
  #
  # Rules:
  #   - Endpoint has addresses in inventory → "static"
  #   - Endpoint has no addresses, has tenant prefix → "dhcp"
  #   - Ambiguous (no data at all) → fail
  #   - Explicit assignment mode in endpoint definition overrides
  # ---------------------------------------------------------------
  deriveAssignmentMode = endpoint: inventoryAddr:
    let
      explicitMode = endpoint.assignment or endpoint.assignmentMode or null;
      hasAddresses =
        builtins.length (inventoryAddr.ipv4 or [ ]) > 0
        || builtins.length (inventoryAddr.ipv6 or [ ]) > 0;
      tenant = endpoint.tenant or "";
    in
    if isNonEmptyString explicitMode then
      if builtins.elem explicitMode
           [ "dhcp" "dhcpv6" "static" "static-only" "disabled"
             "reservation-dhcp" "reservation-dhcpv6" ]
      then explicitMode
      else
        failInventory "endpoints.${endpoint.name or "?"}"
          "${gampRowId}: unsupported assignmentMode '${explicitMode}'"
    else if hasAddresses then
      "static"
    else
      # No addresses, no explicit mode → DHCP with a diagnostic noting the
      # absence of explicit configuration
      "dhcp";

  # ---------------------------------------------------------------
  # Address family classification
  # ---------------------------------------------------------------
  classifyAddressFamily = inventoryAddr:
    let
      hasV4 = builtins.length (inventoryAddr.ipv4 or [ ]) > 0;
      hasV6 = builtins.length (inventoryAddr.ipv6 or [ ]) > 0;
    in
    if hasV4 && hasV6 then "dual"
    else if hasV4 then "ipv4"
    else if hasV6 then "ipv6"
    else "none";

  # ---------------------------------------------------------------
  # Gateway derivation from tenant prefix
  #
  # FS-720-HDS-010-SDS-025-SMS-010 P3/P7: The gateway MUST be a
  # usable host address, not the network (all-zeros) address.
  # stripCidr on e.g. "10.20.20.0/24" yields "10.20.20.0", which is
  # the network address — not routable as a gateway.
  #
  # We replace the last component with "1" to produce the first
  # usable host address in the subnet (e.g. "10.20.20.1").
  # ---------------------------------------------------------------
  deriveGateway4 = prefix:
    let
      cidr = prefix.ipv4 or "";
      addr = if isNonEmptyString cidr then stripCidr cidr else null;
    in
    if addr != null then
      let
        octets = lib.splitString "." addr;
        lastIdx = builtins.length octets - 1;
        gwOctets =
          (lib.take lastIdx octets) ++ [ "1" ];
      in
      lib.concatStringsSep "." gwOctets
    else null;

  deriveGateway6 = prefix:
    let
      cidr = prefix.ipv6 or "";
      addr = if isNonEmptyString cidr then stripCidr cidr else null;
    in
    if addr != null then
      # Compressed form (e.g. "fd42:dead:beef:20::"): append "1" → "::1"
      # Otherwise replace last hextet with "1"
      if lib.hasSuffix "::" addr then
        "${addr}1"
      else
        let
          hextets = lib.splitString ":" addr;
          lastIdx = builtins.length hextets - 1;
          gwHextets =
            (lib.take lastIdx hextets) ++ [ "1" ];
        in
        lib.concatStringsSep ":" gwHextets
    else null;

  # ---------------------------------------------------------------
  # Bridge / attachment surface from runtime targets
  # ---------------------------------------------------------------
  findBridge = tenant:
    let
      bridgeFromPort = port:
        if hasAttr "attach" port && isNonEmptyString (port.attach.bridge or null) then
          port.attach.bridge
        else if hasAttr "hostBridge" port && isNonEmptyString (port.hostBridge or null) then
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

      targetHasTenantAttachment = target:
        builtins.any
          (attachment:
            let
              attrs = attrsOrEmpty attachment;
            in
            (attrs.kind or null) == "tenant" && (attrs.name or null) == tenant)
          (if builtins.isList (target.attachments or null) then target.attachments else [ ]);

      targetMatchesTenant = target:
        let
          logicalName = targetLogicalName target;
        in
        logicalName == "${siteName}-access-${tenant}"
        || lib.hasSuffix "-access-${tenant}" logicalName
        || targetHasTenantAttachment target;

      # Walk runtime targets to find an access node with a tenant port
      # matching this tenant. This mirrors tenantRuntime logic from
      # client-fixtures.nix.
      targetNames = builtins.filter
        (name:
          let
            t = attrsOrEmpty runtimeTargets.${name};
            role = t.role or "";
          in
          role == "access" || builtins.substring 0 7 role == "access-")
        (sortedNames (attrsOrEmpty runtimeTargets));

      firstBridge = builtins.foldl'
        (acc: targetName:
          if acc != null then acc
          else
            let
              t = attrsOrEmpty runtimeTargets.${targetName};
              effective = attrsOrEmpty (t.effectiveRuntimeRealization or null);
              ifaces = attrsOrEmpty (effective.interfaces or t.interfaces or null);
              tenantPorts = builtins.filter
                (ifName:
                  let
                    iface = attrsOrEmpty ifaces.${ifName};
                  in
                  ifName == "tenant-${tenant}" || (iface.tenant or null) == tenant)
                (builtins.attrNames ifaces);
            in
            if tenantPorts != [ ] then
              let
                bridge = bridgeFromPort ifaces.${builtins.head tenantPorts};
              in
              if bridge != null then
                bridge
              else if targetMatchesTenant t then
                builtins.foldl'
                  (fallback: ifName:
                    if fallback != null then fallback
                    else
                      let
                        port = attrsOrEmpty ifaces.${ifName};
                      in
                      bridgeFromPort port)
                  null
                  (sortedNames ifaces)
              else
                null
            else
              null)
        null
        targetNames;
    in
    firstBridge;

  # ---------------------------------------------------------------
  # Namespace owner derivation
  # ---------------------------------------------------------------
  deriveNamespaceOwner = tenant:
    "${siteName}-access-${tenant}";

  # ---------------------------------------------------------------
  # Per-endpoint record construction
  # ---------------------------------------------------------------
  endpointFixtures =
    builtins.listToAttrs (
      builtins.map
        (endpoint:
          let
            name = requireString
              "${gampRowId}: ownership.endpoints: missing name"
              (endpoint.name or null);
            tenant = requireString
              "${gampRowId}: ownership.endpoints.${name}: missing tenant"
              (endpoint.tenant or null);
            prefix = tenantPrefix tenant;
            invAddr = attrsOrEmpty (inventoryEndpoints.${name} or null);
            mode = deriveAssignmentMode endpoint invAddr;
            family = classifyAddressFamily invAddr;
            gw4 = deriveGateway4 prefix;
            gw6 = deriveGateway6 prefix;
            bridge = findBridge tenant;
            namespace = deriveNamespaceOwner tenant;
            key = "${siteName}-${name}";
            isStatic = builtins.elem mode [ "static" "static-only" ];
            isDhcp = builtins.substring 0 4 mode == "dhcp" || mode == "reservation-dhcp" || mode == "reservation-dhcpv6";

            # Static record fields (P3)
            staticRecord =
              if isStatic then
                let
                  addr4 = if builtins.length (invAddr.ipv4 or [ ]) > 0
                          then stripCidr (builtins.head invAddr.ipv4) else null;
                  addr6 = if builtins.length (invAddr.ipv6 or [ ]) > 0
                          then stripCidr (builtins.head invAddr.ipv6) else null;
                  plen4 = if isNonEmptyString (prefix.ipv4 or "")
                          then prefixLen prefix.ipv4 else null;
                  plen6 = if isNonEmptyString (prefix.ipv6 or "")
                          then prefixLen prefix.ipv6 else null;
                in
                { }
                // (if addr4 != null then { address = addr4; } else { })
                // (if addr6 != null then { address6 = addr6; } else { })
                // (if plen4 != null then { prefixLength = plen4; } else { })
                // (if plen6 != null then { prefixLength6 = plen6; } else { })
                // (if gw4 != null then { gateway4 = gw4; } else { })
                // (if gw6 != null then { gateway6 = gw6; } else { })
              else
                { };

            # DHCP record fields (P2)
            dhcpRecord =
              if isDhcp then
                let
                  pool = endpoint.pool or endpoint.dhcpPool or null;
                  reservation = endpoint.reservationBinding
                    or endpoint.reservation or null;
                  conflict = endpoint.conflictBehavior or "reject-overlap";
                in
                { }
                // (if isNonEmptyString (prefix.ipv4 or "") then
                    { servedPrefix4 = prefix.ipv4; } else { })
                // (if isNonEmptyString (prefix.ipv6 or "") then
                    { servedPrefix6 = prefix.ipv6; } else { })
                // (if gw4 != null then { inherit gw4; } else { })
                // (if gw6 != null then { inherit gw6; } else { })
                // (if pool != null then { inherit pool; } else { })
                // (if reservation != null then
                    { reservationBinding = reservation; } else { })
                // { inherit conflict; }
              else
                { };

            # P7: DHCP fixture must have required fields
            _dhcpFields =
              if isDhcp then
                builtins.seq
                  (if !(isNonEmptyString (prefix.ipv4 or "")) &&
                      !(isNonEmptyString (prefix.ipv6 or "")) then
                    failInventory "ownership.prefixes.${tenant}"
                      "${gampRowId} (P7): DHCP endpoint '${name}' has no served prefix for tenant '${tenant}'"
                  else true)
                  (builtins.seq
                    (if gw4 == null && gw6 == null then
                      failInventory "ownership.prefixes.${tenant}"
                        "${gampRowId} (P7): DHCP endpoint '${name}' has no gateway from tenant prefix '${tenant}'"
                    else true)
                    true)
              else
                true;

            # P3: Static fixture must have address
            _staticFields =
              if isStatic then
                builtins.seq
                  (if builtins.length (invAddr.ipv4 or [ ]) == 0 &&
                      builtins.length (invAddr.ipv6 or [ ]) == 0 then
                    failInventory "endpoints.${name}"
                      "${gampRowId} (P3): static endpoint '${name}' has no address data in inventory"
                  else true)
                  true
              else
                true;

            # Reject `kind` != "host" endpoints silently appearing
            _kindCheck =
              if (endpoint.kind or "") != "host" then
                failInventory "ownership.endpoints.${name}"
                  "${gampRowId}: endpoint '${name}' has kind='${endpoint.kind or "?"}' — only 'host' endpoints are supported for endpointAssignment"
              else
                true;
          in
          builtins.seq _dhcpFields (
            builtins.seq _staticFields (
              builtins.seq _kindCheck {
                name = key;
                value =
                  {
                    inherit (endpoint) name tenant;
                    enterprise = enterpriseName;
                    site = siteName;
                    inherit mode family;
                  }
                  // (if isStatic then { static = staticRecord; } else { })
                  // (if isDhcp then { dhcp = dhcpRecord; } else { })
                  // (if bridge != null then { inherit bridge; } else { })
                  // {
                    owningSubstrate = "s-router-test-clients";
                    namespaceOwner = namespace;
                    gampIds = [ gampRowId gampBoundaryId ];
                  };
              }))
        )
        hostEndpoints
    );

  # ---------------------------------------------------------------
  # Diagnostics: identify endpoints with incomplete data
  # ---------------------------------------------------------------
  diagnostics =
    let
      # Endpoints missing from inventory
      missingFromInventory =
        builtins.filter
          (endpoint:
            let name = endpoint.name or "";
            in !(hasAttr name inventoryEndpoints))
          hostEndpoints;

      missingDiags =
        builtins.map
          (ep:
            let name = ep.name or "?";
            in {
              endpoint = name;
              code = "missing-inventory-address";
              message =
                "${gampRowId}: endpoint '${name}' (tenant '${ep.tenant or "?"}') "
                + "has no address data in inventory.endpoints";
              gampId = gampRowId;
            })
          missingFromInventory;

      # Endpoints with ambiguous assignment
      ambiguousEndpoints =
        builtins.filter
          (endpoint:
            let
              name = endpoint.name or "";
              invAddr = attrsOrEmpty (inventoryEndpoints.${name} or null);
              mode = deriveAssignmentMode endpoint invAddr;
              hasAddr = builtins.length (invAddr.ipv4 or [ ]) > 0
                     || builtins.length (invAddr.ipv6 or [ ]) > 0;
            in
            mode == "dhcp" && hasAddr)
          hostEndpoints;

      ambiguousDiags =
        builtins.map
          (ep:
            let name = ep.name or "?";
            in {
              endpoint = name;
              code = "ambiguous-assignment";
              message =
                "${gampRowId}: endpoint '${name}' has inventory addresses "
                + "but no explicit assignmentMode — derived as 'dhcp'; "
                + "consider adding explicit assignmentMode field";
              gampId = gampRowId;
            })
          ambiguousEndpoints;
    in
    missingDiags ++ ambiguousDiags;
in
builtins.seq (builtins.deepSeq endpointFixtures true) {
  # Structured endpoint assignment records keyed by site-endpointName
  endpointAssignment = endpointFixtures;

  # Diagnostics for incomplete or ambiguous data
  inherit diagnostics;

  # GAMP trace metadata
  gampIds = [ gampRowId gampBoundaryId ];
}
