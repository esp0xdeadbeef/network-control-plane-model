{ lib, helpers, realizationIndex, endpointInventoryIndex, inventory ? { } }:

{ enterpriseName, siteName, site }:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    isNonEmptyString
    logicalKey
    requireAttrs
    requireList
    requireRoutes
    requireString
    requireStringList
    sortedNames
    ;

  deriveDefaultReachability =
    import ./default-reachability-model.nix {
      inherit helpers;
    };

  resolveAccessAdvertisements =
    import ./resolve-access-advertisements.nix {
      inherit helpers;
    };

  resolveFirewallIntent =
    import ./resolve-firewall-intent.nix {
      inherit helpers;
    };

  resolvePolicyEndpointBindings =
    import ./resolve-policy-endpoint-bindings.nix {
      inherit helpers;
    };

  ipam =
    import ./ipam.nix {
      inherit lib;
    };

  attrsOrEmpty = value:
    if builtins.isAttrs value then
      value
    else
      { };

  listOrEmpty = value:
    if builtins.isList value then
      value
    else
      [ ];

  failForwarding = path: message:
    throw "forwarding-model update required: ${path}: ${message}";

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
  siteAttrs = requireAttrs sitePath site;

  siteId = requireString "${sitePath}.siteId" (siteAttrs.siteId or null);
  siteDisplayName = requireString "${sitePath}.siteName" (siteAttrs.siteName or null);
  policyNodeName = requireString "${sitePath}.policyNodeName" (siteAttrs.policyNodeName or null);
  upstreamSelectorNodeName = requireString "${sitePath}.upstreamSelectorNodeName" (siteAttrs.upstreamSelectorNodeName or null);
  coreNodeNames = requireStringList "${sitePath}.coreNodeNames" (siteAttrs.coreNodeNames or null);
  uplinkCoreNames = requireStringList "${sitePath}.uplinkCoreNames" (siteAttrs.uplinkCoreNames or null);
  uplinkNames = requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);

  attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);
  links = requireAttrs "${sitePath}.links" (siteAttrs.links or null);
  nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);
  transitAttrs = requireAttrs "${sitePath}.transit" (siteAttrs.transit or null);

  domainsValue = requireAttrs "${sitePath}.domains" (siteAttrs.domains or null);
  domains = {
    tenants = requireList "${sitePath}.domains.tenants" (domainsValue.tenants or null);
    externals = requireList "${sitePath}.domains.externals" (domainsValue.externals or null);
  };

  tenantPrefixOwners =
    requireAttrs "${sitePath}.tenantPrefixOwners" (siteAttrs.tenantPrefixOwners or null);

  communicationContract =
    if builtins.isAttrs (siteAttrs.communicationContract or null) then
      let
        contract = requireAttrs "${sitePath}.communicationContract" siteAttrs.communicationContract;
      in
      {
        allowedRelations =
          requireList "${sitePath}.communicationContract.allowedRelations" (contract.allowedRelations or null);
      }
      // (
        if builtins.isList (contract.services or null) then
          {
            services = contract.services;
          }
        else
          { }
      )
      // (
        if builtins.isList (contract.trafficTypes or null) then
          {
            trafficTypes = contract.trafficTypes;
          }
        else
          { }
      )
    else
      null;

  policyAttrs =
    if builtins.isAttrs (siteAttrs.policy or null) then
      requireAttrs "${sitePath}.policy" siteAttrs.policy
    else
      { };

  inventoryAttrs = attrsOrEmpty inventory;

  # Control-plane routing decisions live in inventory (not forwarding-model).
  siteControlPlaneCfg =
    let
      cp = attrsOrEmpty (inventoryAttrs.controlPlane or null);
      sitesCfg = attrsOrEmpty (cp.sites or null);
      enterpriseCfg = attrsOrEmpty (sitesCfg.${enterpriseName} or null);
    in
    attrsOrEmpty (enterpriseCfg.${siteName} or null);

  siteRouting = attrsOrEmpty (siteControlPlaneCfg.routing or null);
  siteOverlays = attrsOrEmpty (siteControlPlaneCfg.overlays or null);
  siteUplinksCfg = attrsOrEmpty (siteControlPlaneCfg.uplinks or null);
  siteTenantsCfg = attrsOrEmpty (siteControlPlaneCfg.tenants or null);
  siteIpv6Cfg = attrsOrEmpty (siteControlPlaneCfg.ipv6 or null);

  routingMode =
    let
      v = siteRouting.mode or "static";
    in
    if v == "bgp" || v == "static" then v else "static";

  bgpSite =
    if routingMode == "bgp" then
      attrsOrEmpty (siteRouting.bgp or null)
    else
      { };

  bgpSiteAsn = bgpSite.asn or null;
  bgpTopology = bgpSite.topology or "policy-rr";

  normalizeEgressMode = v:
    if v == "static" || v == "bgp" then v else "static";

  uplinkRouting =
    builtins.listToAttrs (
      builtins.map
        (uplinkName:
          let
            uplinkPath = "inventory.controlPlane.sites.${enterpriseName}.${siteName}.uplinks.${uplinkName}.egress";
            uplinkCfg = attrsOrEmpty (siteUplinksCfg.${uplinkName} or null);
            egress = attrsOrEmpty (uplinkCfg.egress or null);
            modeRaw = egress.mode or "static";
            mode = normalizeEgressMode modeRaw;

            staticCfg = attrsOrEmpty (egress.static or null);
            staticRoutes = attrsOrEmpty (staticCfg.routes or null);

            bgpCfg = attrsOrEmpty (egress.bgp or null);
            bgpPeerAsn = bgpCfg.peerAsn or null;
            bgpPeerAddr4 = bgpCfg.peerAddr4 or null;
            bgpPeerAddr6 = bgpCfg.peerAddr6 or null;

            _bgpValid =
              if mode != "bgp" then
                true
              else if !builtins.isInt bgpPeerAsn then
                failInventory "${uplinkPath}.bgp.peerAsn" "bgp uplink egress requires integer peerAsn"
              else if !(isNonEmptyString bgpPeerAddr4 || isNonEmptyString bgpPeerAddr6) then
                failInventory "${uplinkPath}.bgp" "bgp uplink egress requires peerAddr4 and/or peerAddr6"
              else
                true;
          in
          builtins.seq _bgpValid {
            name = uplinkName;
            value =
              {
                mode = mode;
              }
              // lib.optionalAttrs (mode == "static" && builtins.isAttrs (staticCfg.routes or null)) {
                static = {
                  routes = {
                    ipv4 = requireList "${uplinkPath}.static.routes.ipv4" (staticRoutes.ipv4 or [ ]);
                    ipv6 = requireList "${uplinkPath}.static.routes.ipv6" (staticRoutes.ipv6 or [ ]);
                  };
                };
              }
              // lib.optionalAttrs (mode == "bgp") {
                bgp = {
                  peerAsn = bgpPeerAsn;
                }
                // lib.optionalAttrs (isNonEmptyString bgpPeerAddr4) { peerAddr4 = bgpPeerAddr4; }
                // lib.optionalAttrs (isNonEmptyString bgpPeerAddr6) { peerAddr6 = bgpPeerAddr6; };
              };
          })
        uplinkNames
    );

  overlayReachability = attrsOrEmpty (siteAttrs.overlayReachability or null);
  overlayNames = sortedNames overlayReachability;

  overlayProvisioning =
    builtins.listToAttrs (
      builtins.map
        (overlayName:
          let
            overlayPath = "${sitePath}.overlayReachability.${overlayName}";
            ov = requireAttrs overlayPath overlayReachability.${overlayName};
            cfg = attrsOrEmpty (siteOverlays.${overlayName} or null);

            terminateOn =
              lib.sort (a: b: a < b) (
                map toString (listOrEmpty (ov.terminateOn or null))
              );

            overlayNodesCfg = attrsOrEmpty (cfg.nodes or null);
            overlayIpamCfg = attrsOrEmpty (cfg.ipam or null);
            overlayIpamNodesCfg = attrsOrEmpty (overlayIpamCfg.nodes or null);

            overlayIpamV4 = attrsOrEmpty (overlayIpamCfg.ipv4 or null);
            overlayIpamV6 = attrsOrEmpty (overlayIpamCfg.ipv6 or null);

            ipamV4Prefix = if isNonEmptyString (overlayIpamV4.prefix or null) then overlayIpamV4.prefix else null;
            ipamV6Prefix = if isNonEmptyString (overlayIpamV6.prefix or null) then overlayIpamV6.prefix else null;

            ipamV4PerNodePrefixLength =
              if builtins.isInt (overlayIpamV4.perNodePrefixLength or null) then
                overlayIpamV4.perNodePrefixLength
              else
                32;

            ipamV6PerNodePrefixLength =
              if builtins.isInt (overlayIpamV6.perNodePrefixLength or null) then
                overlayIpamV6.perNodePrefixLength
              else
                128;

            ipamV4OffsetStart =
              if builtins.isInt (overlayIpamV4.offsetStart or null) then
                overlayIpamV4.offsetStart
              else
                10;

            ipamV6OffsetStart =
              if builtins.isInt (overlayIpamV6.offsetStart or null) then
                overlayIpamV6.offsetStart
              else
                10;

            resolveOverlayAddr =
              { family, nodeName, idx }:
              let
                nodeCfg = attrsOrEmpty (overlayNodesCfg.${nodeName} or null);
                nodeIpamCfg = attrsOrEmpty (overlayIpamNodesCfg.${nodeName} or null);
                nodeOverrideAddr4 = nodeCfg.addr4 or (nodeIpamCfg.addr4 or null);
                nodeOverrideAddr6 = nodeCfg.addr6 or (nodeIpamCfg.addr6 or null);
              in
              if family == 4 then
                if isNonEmptyString nodeOverrideAddr4 then
                  nodeOverrideAddr4
                else if ipamV4Prefix != null then
                  ipam.allocOne {
                    family = 4;
                    prefix = ipamV4Prefix;
                    perNodePrefixLength = ipamV4PerNodePrefixLength;
                    offset = ipamV4OffsetStart + idx;
                  }
                else
                  null
              else if family == 6 then
                if isNonEmptyString nodeOverrideAddr6 then
                  nodeOverrideAddr6
                else if ipamV6Prefix != null then
                  ipam.allocOne {
                    family = 6;
                    prefix = ipamV6Prefix;
                    perNodePrefixLength = ipamV6PerNodePrefixLength;
                    offset = ipamV6OffsetStart + idx;
                  }
                else
                  null
              else
                null;

            overlayNodeAddrs =
              builtins.listToAttrs (
                lib.imap0
                  (idx: nodeName:
                    let
                      addr4 = resolveOverlayAddr { family = 4; inherit nodeName idx; };
                      addr6 = resolveOverlayAddr { family = 6; inherit nodeName idx; };
                    in
                    {
                      name = nodeName;
                      value =
                        { }
                        // lib.optionalAttrs (isNonEmptyString addr4) { addr4 = addr4; }
                        // lib.optionalAttrs (isNonEmptyString addr6) { addr6 = addr6; };
                    })
                  terminateOn
              );
          in
          {
            name = overlayName;
            value =
              {
                name = overlayName;
                peerSite = ov.peerSite or null;
                terminateOn = terminateOn;
                nodes = overlayNodeAddrs;
              }
              // lib.optionalAttrs (isNonEmptyString (cfg.provider or null)) { provider = cfg.provider; }
              // lib.optionalAttrs (builtins.isAttrs (cfg.nebula or null)) { nebula = cfg.nebula; };
          })
        overlayNames
    );

  # IPv6 plan: keep forwarding-model technique-agnostic (no PD/BGP/etc. there).
  #
  # If PD is enabled, CPM emits deterministic tenant "slots" that renderers can
  # use to allocate /64s from the delegated prefix at runtime.
  parsePrefixLen =
    prefix:
    let
      m = builtins.match ".*/([0-9]+)$" (toString prefix);
    in
    if m == null then null else builtins.fromJSON (builtins.head m);

  validatePrefixLen =
    { path, prefix, expected }:
    let
      len = parsePrefixLen prefix;
    in
    if len == null then
      failInventory path "prefix '${toString prefix}' must include a /<len> suffix"
    else if len != expected then
      failInventory path "prefix '${toString prefix}' must be a /${toString expected}"
    else
      true;

  ipv6PdCfg = attrsOrEmpty (siteIpv6Cfg.pd or null);

  ipv6PdUplink =
    if isNonEmptyString (ipv6PdCfg.uplink or null) then
      toString ipv6PdCfg.uplink
    else
      null;

  ipv6PdDelegatedPrefixLength =
    if ipv6PdUplink == null then
      null
    else if builtins.isInt (ipv6PdCfg.delegatedPrefixLength or null) then
      ipv6PdCfg.delegatedPrefixLength
    else
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd.delegatedPrefixLength"
        "ipv6.pd.delegatedPrefixLength is required and must be an integer when ipv6.pd.uplink is set";

  ipv6PdPerTenantPrefixLength =
    if ipv6PdUplink == null then
      null
    else if builtins.isInt (ipv6PdCfg.perTenantPrefixLength or null) then
      ipv6PdCfg.perTenantPrefixLength
    else
      64;

  _validatePdUplink =
    if ipv6PdUplink == null then
      true
    else if builtins.elem ipv6PdUplink uplinkNames then
      true
    else
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd.uplink"
        "ipv6.pd.uplink '${ipv6PdUplink}' must match a declared site uplink name: ${builtins.toJSON uplinkNames}";

  _validatePdPrefixLengths =
    if ipv6PdUplink == null then
      true
    else if ipv6PdDelegatedPrefixLength < 48 || ipv6PdDelegatedPrefixLength > 64 then
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd.delegatedPrefixLength"
        "delegatedPrefixLength must be between /48 and /64 (got /${toString ipv6PdDelegatedPrefixLength})"
    else if ipv6PdPerTenantPrefixLength < ipv6PdDelegatedPrefixLength || ipv6PdPerTenantPrefixLength > 64 then
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd.perTenantPrefixLength"
        "perTenantPrefixLength must be between delegatedPrefixLength and /64 (got /${toString ipv6PdPerTenantPrefixLength})"
    else
      true;

  pdSlotCount =
    if ipv6PdUplink == null then
      0
    else
      let
        diff = ipv6PdPerTenantPrefixLength - ipv6PdDelegatedPrefixLength;
        pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);
      in
      pow2 diff;

  tenantNames = map (t: requireString "${sitePath}.domains.tenants[].name" (t.name or null)) domains.tenants;

  tenantIpv6Mode =
    tenantName:
    let
      tcfg = attrsOrEmpty (siteTenantsCfg.${tenantName} or null);
      v6 = attrsOrEmpty (tcfg.ipv6 or null);
      mode = v6.mode or null;
    in
    if ipv6PdUplink == null then
      (if builtins.isString mode && mode != "" then toString mode else "slaac")
    else if builtins.isString mode && mode != "" then
      let
        m = toString mode;
      in
      if m == "slaac" || m == "dhcpv6" || m == "static" then
        m
      else
        failInventory
          "inventory.controlPlane.sites.${enterpriseName}.${siteName}.tenants.${tenantName}.ipv6.mode"
          "ipv6.mode must be one of: \"slaac\", \"dhcpv6\", \"static\" (got ${builtins.toJSON mode})"
    else
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.tenants.${tenantName}.ipv6.mode"
        "ipv6.mode is required when ipv6.pd.uplink is set";

  tenantStaticPrefixes =
    tenantName:
    let
      tcfg = attrsOrEmpty (siteTenantsCfg.${tenantName} or null);
      v6 = attrsOrEmpty (tcfg.ipv6 or null);
      prefixes = v6.prefixes or null;
      path = "inventory.controlPlane.sites.${enterpriseName}.${siteName}.tenants.${tenantName}.ipv6.prefixes";
    in
    if tenantIpv6Mode tenantName != "static" then
      [ ]
    else if builtins.isList prefixes then
      builtins.seq
        (builtins.foldl' (acc: p: builtins.seq (validatePrefixLen { path = path; prefix = p; expected = 64; }) acc) true prefixes)
        (map toString prefixes)
    else
      failInventory path "ipv6.prefixes is required (list of /64s) when ipv6.mode = \"static\"";

  pdTenants =
    if ipv6PdUplink == null then
      [ ]
    else
      lib.sort (a: b: a < b) (lib.filter (t: tenantIpv6Mode t != "static") tenantNames);

  _validatePdSlotsEnough =
    if ipv6PdUplink == null then
      true
    else if builtins.length pdTenants <= pdSlotCount then
      true
    else
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd"
        "not enough PD /${toString ipv6PdPerTenantPrefixLength} slots in delegated /${toString ipv6PdDelegatedPrefixLength} for ${toString (builtins.length pdTenants)} tenants (capacity ${toString pdSlotCount})";

  pdTenantSlots =
    builtins.listToAttrs (
      builtins.genList (idx: {
        name = builtins.elemAt pdTenants idx;
        value = idx;
      }) (builtins.length pdTenants)
    );

  ipv6Plan =
    builtins.seq _validatePdUplink (
      builtins.seq _validatePdPrefixLengths (
        builtins.seq _validatePdSlotsEnough (
          if ipv6PdUplink == null then
            null
          else
            {
              pd = {
                uplink = ipv6PdUplink;
                delegatedPrefixLength = ipv6PdDelegatedPrefixLength;
                perTenantPrefixLength = ipv6PdPerTenantPrefixLength;
                tenantSlots = pdTenantSlots;
              };
              tenants = builtins.listToAttrs (
                map (tenantName: {
                  name = tenantName;
                  value =
                    let
                      mode = tenantIpv6Mode tenantName;
                      slot = pdTenantSlots.${tenantName} or null;
                    in
                    {
                      inherit mode;
                    }
                    // (
                      if mode == "static" then
                        {
                          prefixes = tenantStaticPrefixes tenantName;
                        }
                      else
                        {
                          pd = {
                            inherit slot;
                            prefixLength = ipv6PdPerTenantPrefixLength;
                          };
                        }
                    );
                }) tenantNames
              );
            }
        )
      )
    );

  routerRoleSet = {
    access = true;
    core = true;
    downstream-selector = true;
    policy = true;
    upstream-selector = true;
  };

  attachmentLookup =
    ensureUniqueEntries
      "${sitePath}.attachments"
      (
        builtins.genList
          (idx:
            let
              attachmentPath = "${sitePath}.attachments[${toString idx}]";
              attachment = requireAttrs attachmentPath (builtins.elemAt attachments idx);
              kind = requireString "${attachmentPath}.kind" (attachment.kind or null);
              name = requireString "${attachmentPath}.name" (attachment.name or null);
              unit = requireString "${attachmentPath}.unit" (attachment.unit or null);
            in
            {
              name = "${unit}|${kind}|${name}";
              value = {
                inherit kind name unit;
                id = "attachment::${unit}::${kind}::${name}";
              };
            })
          (builtins.length attachments)
      );

  siteLinks =
    lib.mapAttrsSorted
      (linkName: linkValue:
        let
          linkPath = "${sitePath}.links.${linkName}";
          link = requireAttrs linkPath linkValue;
        in
        link
        // {
          name = linkName;
          id = requireString "${linkPath}.id" (link.id or null);
          kind = requireString "${linkPath}.kind" (link.kind or null);
        })
      links;

  requireExplicitHostUplinkAddressing = {
    ifacePath,
    targetHostName,
    targetId,
    hostUplink
  }:
    let
      uplinkName =
        if isNonEmptyString (hostUplink.uplinkName or null) then
          hostUplink.uplinkName
        else if isNonEmptyString (hostUplink.name or null) then
          hostUplink.name
        else
          failInventory
            "inventory.deployment.hosts.${targetHostName}.uplinks"
            "runtime realization for ${ifacePath} on realized target '${targetId}' resolved an unnamed host uplink";

      requireFamilyMethod = familyName: familyValue:
        if familyValue == null then
          false
        else if !builtins.isAttrs familyValue then
          failInventory
            "inventory.deployment.hosts.${targetHostName}.uplinks.${uplinkName}.${familyName}"
            "runtime realization for ${ifacePath} on realized target '${targetId}' requires this value to be an attribute set"
        else if !isNonEmptyString (familyValue.method or null) then
          failInventory
            "inventory.deployment.hosts.${targetHostName}.uplinks.${uplinkName}.${familyName}.method"
            "runtime realization for ${ifacePath} on realized target '${targetId}' requires this field to be explicitly defined"
        else
          true;

      hasIPv4 = requireFamilyMethod "ipv4" (hostUplink.ipv4 or null);
      hasIPv6 = requireFamilyMethod "ipv6" (hostUplink.ipv6 or null);
    in
    if hasIPv4 || hasIPv6 then
      true
    else
      failInventory
        "inventory.deployment.hosts.${targetHostName}.uplinks.${uplinkName}"
        "runtime realization for ${ifacePath} on realized target '${targetId}' requires explicit upstream addressing in inventory.deployment.hosts.${targetHostName}.uplinks.${uplinkName}.ipv4 and/or ipv6";

  resolveBackingRef = nodeName: ifName: iface:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      kind = requireString "${ifacePath}.kind" (iface.kind or null);
    in
    if kind == "tenant" then
      let
        tenantName = requireString "${ifacePath}.tenant" (iface.tenant or null);
        attachmentKey = "${nodeName}|tenant|${tenantName}";
        attachment =
          if hasAttr attachmentKey attachmentLookup then
            attachmentLookup.${attachmentKey}
          else
            failForwarding
              ifacePath
              "tenant interface requires explicit site.attachments entry; add { kind = \"tenant\"; name = \"${tenantName}\"; unit = \"${nodeName}\"; } to ${sitePath}.attachments";
      in
      {
        kind = "attachment";
        id = attachment.id;
        name = attachment.name;
      }
    else if kind == "overlay" then
      let
        overlayName = requireString "${ifacePath}.overlay" (iface.overlay or null);
      in
      {
        kind = "overlay";
        id = "overlay::${enterpriseName}.${siteName}::${overlayName}";
        name = overlayName;
      }
    else
      let
        linkName = requireString "${ifacePath}.link" (iface.link or null);
        link =
          if hasAttr linkName siteLinks then
            siteLinks.${linkName}
          else
            failForwarding
              "${ifacePath}.link"
              "input contract failure: ${ifacePath}.link references unknown site link '${linkName}'";
      in
      {
        kind = "link";
        id = link.id;
        name = linkName;
        linkKind = link.kind;
      }
      // (
        if kind == "wan" then
          {
            upstreamAlias = requireString "${ifacePath}.upstream" (iface.upstream or null);
          }
        else
          { }
      );

  explicitUplinkRoute = family: dst:
    {
      inherit dst;
      intent = {
        kind =
          if (family == 4 && dst == "0.0.0.0/0") || (family == 6 && dst == "::/0") then
            "default-reachability"
          else
            "uplink-learned-reachability";
        source = "explicit-uplink";
      };
      proto = "upstream";
    };

  buildExplicitInterfaceEntry = {
    nodeName,
    ifName,
    iface,
    portBindings,
    targetHostName,
    targetId,
    realizedTarget
  }:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      ifaceAttrs = requireAttrs ifacePath iface;
      sourceKind = requireString "${ifacePath}.kind" (ifaceAttrs.kind or null);
      sourceIfName = requireString "${ifacePath}.interface" (ifaceAttrs.interface or null);
      backingRef = resolveBackingRef nodeName ifName ifaceAttrs;

      portBinding =
        if sourceKind == "p2p" then
          if hasAttr backingRef.name portBindings.byLink then
            portBindings.byLink.${backingRef.name}
          else
            null
        else if sourceKind == "wan" then
          if hasAttr (backingRef.upstreamAlias or "") portBindings.byUplink then
            portBindings.byUplink.${backingRef.upstreamAlias}
          else
            null
        else if sourceKind == "tenant" && hasAttr ifName portBindings.byLogicalInterface then
          portBindings.byLogicalInterface.${ifName}
        else
          null;

      requiresExplicitPortRealization =
        realizedTarget
        && (
          sourceKind == "p2p"
          || sourceKind == "wan"
        );

      _requiredPortBinding =
        if requiresExplicitPortRealization && portBinding == null then
          if sourceKind == "p2p" then
            failInventory
              "${targetId}.ports"
              "${ifacePath} on realized target '${targetId}' requires explicit port realization for backing link '${backingRef.id}'"
          else if sourceKind == "wan" then
            failInventory
              "${targetId}.ports"
              "${ifacePath} on realized target '${targetId}' requires explicit uplink port realization for uplink '${backingRef.upstreamAlias}'"
          else
            failInventory
              "${targetId}.ports"
              "${ifacePath} on realized target '${targetId}' requires explicit port realization for logical interface '${ifName}'"
        else
          true;

      runtimeIfName =
        if portBinding != null then
          portBinding.runtimeIfName
        else
          sourceIfName;

      effectiveAddr4 =
        let
          overlayNodes =
            if sourceKind == "overlay" && hasAttr (backingRef.name or "") overlayProvisioning then
              attrsOrEmpty (overlayProvisioning.${backingRef.name}.nodes or null)
            else
              { };
          overlayAddr4 =
            if sourceKind == "overlay" && hasAttr nodeName overlayNodes then
              overlayNodes.${nodeName}.addr4 or null
            else
              null;
        in
        if sourceKind == "overlay" && isNonEmptyString overlayAddr4 then
          overlayAddr4
        else if portBinding != null && isNonEmptyString (portBinding.interfaceAddr4 or null) then
          portBinding.interfaceAddr4
        else
          ifaceAttrs.addr4 or null;

      effectiveAddr6 =
        let
          overlayNodes =
            if sourceKind == "overlay" && hasAttr (backingRef.name or "") overlayProvisioning then
              attrsOrEmpty (overlayProvisioning.${backingRef.name}.nodes or null)
            else
              { };
          overlayAddr6 =
            if sourceKind == "overlay" && hasAttr nodeName overlayNodes then
              overlayNodes.${nodeName}.addr6 or null
            else
              null;
        in
        if sourceKind == "overlay" && isNonEmptyString overlayAddr6 then
          overlayAddr6
        else if portBinding != null && isNonEmptyString (portBinding.interfaceAddr6 or null) then
          portBinding.interfaceAddr6
        else
          ifaceAttrs.addr6 or null;

      resolvedHostUplink =
        if portBinding != null && builtins.isAttrs (portBinding.hostUplink or null) then
          portBinding.hostUplink
        else
          null;

      validatedHostUplink =
        if realizedTarget && sourceKind == "wan" then
          if resolvedHostUplink == null then
            failInventory
              "inventory.deployment.hosts.${targetHostName}.uplinks"
              "${ifacePath} on realized target '${targetId}' requires explicit host uplink bridge mapping in inventory.deployment.hosts.${targetHostName}.uplinks"
          else
            builtins.seq
              (requireExplicitHostUplinkAddressing {
                inherit ifacePath targetHostName targetId;
                hostUplink = resolvedHostUplink;
              })
              resolvedHostUplink
        else
          resolvedHostUplink;

      baseValue =
        {
          runtimeTarget = targetId;
          logicalNode = nodeName;
          sourceInterface = ifName;
          sourceKind = sourceKind;
          runtimeIfName = runtimeIfName;
          renderedIfName = runtimeIfName;
          addr4 = effectiveAddr4;
          addr6 = effectiveAddr6;
          routes = requireRoutes ifacePath (ifaceAttrs.routes or null);
          backingRef = builtins.removeAttrs backingRef [ "linkKind" "upstreamAlias" ];
        }
        // (
          if portBinding != null && builtins.isAttrs (portBinding.attach or null) then
            {
              attach = portBinding.attach;
            }
          else
            { }
        )
        // (
          if sourceKind == "wan" then
            {
              upstream = requireString "${ifacePath}.upstream" (ifaceAttrs.upstream or null);
            }
          else
            { }
        )
        // (
          if sourceKind == "wan" && builtins.isAttrs (ifaceAttrs.wan or null) then
            {
              wan = ifaceAttrs.wan;
            }
          else
            { }
        )
        // (
          if sourceKind == "tenant" && ((ifaceAttrs.logical or false) == true) then
            {
              logical = true;
            }
          else
            { }
        )
        // (
          if sourceKind == "wan" && validatedHostUplink != null then
            {
              hostUplink = validatedHostUplink;
            }
          else
            { }
        )
        // (
          if sourceKind == "wan" && builtins.isAttrs (validatedHostUplink.ipv4 or null) then
            {
              ipv4 = validatedHostUplink.ipv4;
            }
          else
            { }
        )
        // (
          if sourceKind == "wan" && builtins.isAttrs (validatedHostUplink.ipv6 or null) then
            {
              ipv6 = validatedHostUplink.ipv6;
            }
          else
            { }
        );
    in
    builtins.seq
      _requiredPortBinding
      {
        name = ifName;
        value = baseValue;
      };

  buildSyntheticUplinkInterfaceEntry = {
    nodeName,
    uplinkName,
    uplinkValue,
    portBindings,
    targetHostName,
    targetId,
    realizedTarget
  }:
    let
      uplinkPath = "${sitePath}.nodes.${nodeName}.uplinks.${uplinkName}";
      uplinkAttrs = requireAttrs uplinkPath uplinkValue;

      portBinding =
        if hasAttr uplinkName portBindings.byUplink then
          portBindings.byUplink.${uplinkName}
        else
          null;

      _requiredPortBinding =
        if realizedTarget && portBinding == null then
          failInventory
            "${targetId}.ports"
            "${uplinkPath} on realized target '${targetId}' requires explicit uplink port realization for uplink '${uplinkName}'"
        else
          true;

      runtimeIfName =
        if portBinding != null then
          portBinding.runtimeIfName
        else
          uplinkName;

      resolvedHostUplink =
        if portBinding != null && builtins.isAttrs (portBinding.hostUplink or null) then
          portBinding.hostUplink
        else
          null;

      validatedHostUplink =
        if realizedTarget then
          if resolvedHostUplink == null then
            failInventory
              "inventory.deployment.hosts.${targetHostName}.uplinks"
              "${uplinkPath} on realized target '${targetId}' requires explicit host uplink mapping in inventory.deployment.hosts.${targetHostName}.uplinks"
          else
            builtins.seq
              (requireExplicitHostUplinkAddressing {
                ifacePath = uplinkPath;
                inherit targetHostName targetId;
                hostUplink = resolvedHostUplink;
              })
              resolvedHostUplink
        else
          resolvedHostUplink;

      routes = {
        ipv4 =
          builtins.map
            (dst: explicitUplinkRoute 4 dst)
            (
              if uplinkAttrs ? ipv4 then
                requireStringList "${uplinkPath}.ipv4" uplinkAttrs.ipv4
              else
                [ ]
            );
        ipv6 =
          builtins.map
            (dst: explicitUplinkRoute 6 dst)
            (
              if uplinkAttrs ? ipv6 then
                requireStringList "${uplinkPath}.ipv6" uplinkAttrs.ipv6
              else
                [ ]
            );
      };

      value =
        {
          runtimeTarget = targetId;
          logicalNode = nodeName;
          sourceInterface = uplinkName;
          sourceKind = "wan";
          runtimeIfName = runtimeIfName;
          renderedIfName = runtimeIfName;
          addr4 = uplinkAttrs.addr4 or null;
          addr6 = uplinkAttrs.addr6 or null;
          inherit routes;
          backingRef = {
            kind = "link";
            id = "uplink::${enterpriseName}.${siteName}::${uplinkName}";
            name = uplinkName;
          };
          upstream = uplinkName;
          wan = {
            ipv4 =
              if uplinkAttrs ? ipv4 then
                requireStringList "${uplinkPath}.ipv4" uplinkAttrs.ipv4
              else
                [ ];
            ipv6 =
              if uplinkAttrs ? ipv6 then
                requireStringList "${uplinkPath}.ipv6" uplinkAttrs.ipv6
              else
                [ ];
          };
        }
        // (
          if portBinding != null && builtins.isAttrs (portBinding.attach or null) then
            {
              attach = portBinding.attach;
            }
          else
            { }
        )
        // (
          if validatedHostUplink != null then
            {
              hostUplink = validatedHostUplink;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (validatedHostUplink.ipv4 or null) then
            {
              ipv4 = validatedHostUplink.ipv4;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (validatedHostUplink.ipv6 or null) then
            {
              ipv6 = validatedHostUplink.ipv6;
            }
          else
            { }
        );
    in
    builtins.seq
      _requiredPortBinding
      {
        name = uplinkName;
        inherit value;
      };

  defaultPortBindings = {
    byLink = { };
    byLogicalInterface = { };
    byUplink = { };
    portDefs = { };
  };

  hasExplicitWANForUplink = nodeInterfaces: uplinkName:
    builtins.any
      (ifName:
        let
          iface = requireAttrs "${sitePath}.nodes[*].interfaces.${ifName}" nodeInterfaces.${ifName};
        in
        (iface.kind or null) == "wan"
        && (iface.upstream or null) == uplinkName)
      (sortedNames nodeInterfaces);

  normalizeDeclaredContainer = nodePath: nodeName: containerIndex: containerValue:
    let
      containerPath = "${nodePath}.containers[${toString containerIndex}]";
      container =
        if builtins.isAttrs containerValue then
          requireAttrs containerPath containerValue
        else if builtins.isString containerValue then
          {
            name = requireString containerPath containerValue;
          }
        else
          failForwarding
            containerPath
            "container declarations must be strings or attribute sets with explicit names";
    in
    if !isNonEmptyString (container.name or null) then
      failForwarding "${containerPath}.name" "container name is required"
    else
      {
        logicalName = container.name;
      }
      // (
        if builtins.isString (container.kind or null) && container.kind != "" then
          {
            kind = container.kind;
          }
        else
          { }
      )
      // (
        if builtins.isList (container.services or null) then
          {
            services = container.services;
          }
        else
          { }
      )
      // (
        if builtins.isAttrs (container.meta or null) then
          {
            meta = container.meta;
          }
        else
          { }
      );

  resolveRuntimeContainers = {
    nodePath,
    nodeName,
    realizedTarget,
    targetId,
    targetDef,
    nodeAttrs
  }:
    let
      declaredContainersRaw =
        if builtins.isList (nodeAttrs.containers or null) then
          nodeAttrs.containers
        else
          [ ];

      declaredContainers =
        builtins.map
          (idx:
            normalizeDeclaredContainer nodePath nodeName idx (builtins.elemAt declaredContainersRaw idx))
          (builtins.genList (idx: idx) (builtins.length declaredContainersRaw));

      declaredByName =
        ensureUniqueEntries
          "${nodePath}.containers"
          (
            builtins.map
              (container: {
                name = container.logicalName;
                value = container;
              })
              declaredContainers
          );

      realizedBindings =
        if realizedTarget then
          targetDef.containerBindings or { }
        else
          { };

      _coverage =
        if realizedTarget then
          builtins.deepSeq
            (builtins.map
              (containerName:
                if hasAttr containerName realizedBindings then
                  true
                else
                  failInventory
                    "${targetDef.nodePath}.containers.${containerName}"
                    "runtime target '${targetId}' must explicitly realize forwarding-model container '${containerName}'")
              (sortedNames declaredByName))
            true
        else
          true;

      _noUnexpected =
        if realizedTarget then
          builtins.deepSeq
            (builtins.map
              (containerName:
                if hasAttr containerName declaredByName then
                  true
                else
                  failInventory
                    "${targetDef.nodePath}.containers.${containerName}"
                    "references unknown forwarding-model container '${containerName}' on logical node '${nodeName}'")
              (sortedNames realizedBindings))
            true
        else
          true;

      merged =
        builtins.map
          (containerName:
            let
              declared = declaredByName.${containerName};
              realized =
                if hasAttr containerName realizedBindings then
                  realizedBindings.${containerName}
                else
                  null;
              runtimeName =
                if realized != null then
                  requireString
                    "${targetDef.nodePath}.containers.${containerName}.runtimeName"
                    (realized.runtimeName or null)
                else
                  containerName;
            in
            declared
            // {
              name = containerName;
              logicalName = containerName;
              runtimeName = runtimeName;
              container = runtimeName;
            })
          (sortedNames declaredByName);
    in
    builtins.seq
      _coverage
      (builtins.seq
        _noUnexpected
        merged);

  _validateSiteRouting =
    if routingMode == "bgp" then
      if !builtins.isInt bgpSiteAsn then
        failInventory "inventory.controlPlane.sites.${enterpriseName}.${siteName}.routing.bgp.asn" "bgp mode requires integer 'asn'"
      else if bgpTopology != "policy-rr" then
        failInventory "inventory.controlPlane.sites.${enterpriseName}.${siteName}.routing.bgp.topology" "only 'policy-rr' is supported right now"
      else
        true
    else
      true;

  loopbacksByNode =
    builtins.listToAttrs (
      builtins.map
        (nodeName:
          let
            nodePath = "${sitePath}.nodes.${nodeName}";
            nodeAttrs = requireAttrs nodePath nodes.${nodeName};
            loopback = requireAttrs "${nodePath}.loopback" (nodeAttrs.loopback or null);
          in
          {
            name = nodeName;
            value = {
              addr4 = requireString "${nodePath}.loopback.ipv4" (loopback.ipv4 or null);
              addr6 = requireString "${nodePath}.loopback.ipv6" (loopback.ipv6 or null);
            };
          })
        (sortedNames nodes)
    );

  isHostRoute4 = dst: builtins.isString dst && lib.hasSuffix "/32" dst;
  isHostRoute6 = dst: builtins.isString dst && lib.hasSuffix "/128" dst;

  filterRoutesForBgp =
    routes:
    let
      routesAttrs = attrsOrEmpty routes;
      v4 = listOrEmpty (routesAttrs.ipv4 or null);
      v6 = listOrEmpty (routesAttrs.ipv6 or null);
      keep4 = r:
        let
          dst = r.dst or null;
          proto = r.proto or null;
        in
        builtins.isAttrs r
        && builtins.isString dst
        && (
          dst == "0.0.0.0/0"
          || proto == "uplink"
          || isHostRoute4 dst
        );
      keep6 = r:
        let
          dst = r.dst or null;
          proto = r.proto or null;
        in
        builtins.isAttrs r
        && builtins.isString dst
        && (
          dst == "::/0"
          || proto == "uplink"
          || isHostRoute6 dst
        );
    in
    {
      ipv4 = builtins.filter keep4 v4;
      ipv6 = builtins.filter keep6 v6;
    };

  bgpNeighborsForNode =
    nodeName:
    let
      isRouterNodeName =
        n:
        let
          nodePath = "${sitePath}.nodes.${n}";
          nodeAttrs = requireAttrs nodePath nodes.${n};
          roleRaw = nodeAttrs.role or null;
          role = if builtins.isString roleRaw then roleRaw else "";
        in
        isNonEmptyString role && hasAttr role routerRoleSet;

      routerNodeNames = builtins.filter isRouterNodeName (sortedNames nodes);

      isPolicy = nodeName == policyNodeName;
      peerNames =
        if isPolicy then
          builtins.filter (n: n != policyNodeName) routerNodeNames
        else
          [ policyNodeName ];
    in
    builtins.map
      (peerName:
        let
          peerLoop = loopbacksByNode.${peerName};
        in
        {
          peer_name = peerName;
          peer_asn = bgpSiteAsn;
          peer_addr4 = peerLoop.addr4;
          peer_addr6 = peerLoop.addr6;
          update_source = "lo";
          route_reflector_client = isPolicy;
        })
      peerNames;

  buildRuntimeTarget = nodeName:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath nodes.${nodeName};

      nodeRoleRaw = nodeAttrs.role or null;
      nodeRole = if builtins.isString nodeRoleRaw then nodeRoleRaw else "";

      isBgpRouter =
        routingMode == "bgp"
        && isNonEmptyString nodeRole
        && hasAttr nodeRole routerRoleSet;

      effectiveRoutingMode = if isBgpRouter then "bgp" else "static";

      logical = {
        enterprise = enterpriseName;
        site = siteName;
        name = nodeName;
      };

      logicalId = logicalKey logical;

      realizedTarget =
        hasAttr logicalId realizationIndex.byLogical;

      targetId =
        if realizedTarget then
          realizationIndex.byLogical.${logicalId}
        else
          nodeName;

      targetDef =
        if realizedTarget then
          realizationIndex.targetDefs.${targetId}
        else
          null;

      targetHostName =
        if realizedTarget then
          requireString "${targetDef.nodePath}.host" (targetDef.node.host or null)
        else
          null;

      targetPlatform =
        if realizedTarget then
          requireString "${targetDef.nodePath}.platform" (targetDef.node.platform or null)
        else
          null;

      portBindings =
        if realizedTarget then
          targetDef.portBindings
        else
          defaultPortBindings;

      nodeInterfaces = requireAttrs "${nodePath}.interfaces" (nodeAttrs.interfaces or null);

      explicitEntries =
        builtins.map
          (ifName:
            buildExplicitInterfaceEntry {
              inherit nodeName ifName portBindings targetHostName targetId realizedTarget;
              iface = nodeInterfaces.${ifName};
            })
          (sortedNames nodeInterfaces);

      uplinkAttrs =
        if builtins.isAttrs (nodeAttrs.uplinks or null) then
          nodeAttrs.uplinks
        else
          { };

      syntheticEntries =
        builtins.map
          (uplinkName:
            buildSyntheticUplinkInterfaceEntry {
              inherit nodeName uplinkName portBindings targetHostName targetId realizedTarget;
              uplinkValue = uplinkAttrs.${uplinkName};
            })
          (
            builtins.filter
              (uplinkName: !hasExplicitWANForUplink nodeInterfaces uplinkName)
              (sortedNames uplinkAttrs)
          );

      runtimeInterfaces =
        builtins.listToAttrs (explicitEntries ++ syntheticEntries);

      effectiveRuntimeInterfaces =
        if isBgpRouter then
          lib.mapAttrs (_ifName: iface: iface // { routes = filterRoutesForBgp (iface.routes or { }); }) runtimeInterfaces
        else
          runtimeInterfaces;

      ebgpNeighbors =
        if !isBgpRouter then
          [ ]
        else
          lib.concatMap (
            ifName:
            let
              iface = effectiveRuntimeInterfaces.${ifName};
              upstream = iface.upstream or null;
              uplinkCfg =
                if isNonEmptyString upstream && hasAttr upstream uplinkRouting then
                  uplinkRouting.${upstream}
                else
                  null;
              uplinkMode = if uplinkCfg == null then null else uplinkCfg.mode or null;
              uplinkBgp = if uplinkCfg == null then { } else attrsOrEmpty (uplinkCfg.bgp or null);
              peerAsn = uplinkBgp.peerAsn or null;
              peerAddr4 = uplinkBgp.peerAddr4 or null;
              peerAddr6 = uplinkBgp.peerAddr6 or null;
            in
            if (iface.sourceKind or null) != "wan" || uplinkMode != "bgp" then
              [ ]
            else
              [
                (
                  {
                    peer_name = "uplink-${upstream}";
                    peer_asn = peerAsn;
                    update_source = iface.runtimeIfName or null;
                    route_reflector_client = false;
                  }
                  // lib.optionalAttrs (isNonEmptyString peerAddr4) { peer_addr4 = peerAddr4; }
                  // lib.optionalAttrs (isNonEmptyString peerAddr6) { peer_addr6 = peerAddr6; }
                )
              ]
          ) (sortedNames effectiveRuntimeInterfaces);

      loopback = requireAttrs "${nodePath}.loopback" (nodeAttrs.loopback or null);

      placement =
        if realizedTarget then
          {
            kind = "inventory-realization";
            target = targetId;
            host = targetHostName;
            platform = targetPlatform;
          }
        else
          {
            kind = "logical-node";
            target = nodeName;
          };

      runtimeContainers =
        resolveRuntimeContainers {
          inherit nodePath nodeName realizedTarget targetId targetDef nodeAttrs;
        };

      value =
        {
          logicalNode = logical;
          role = nodeAttrs.role or null;
          routingMode = effectiveRoutingMode;
          placement = placement;
          effectiveRuntimeRealization = {
            loopback = {
              addr4 = requireString "${nodePath}.loopback.ipv4" (loopback.ipv4 or null);
              addr6 = requireString "${nodePath}.loopback.ipv6" (loopback.ipv6 or null);
            };
            interfaces = effectiveRuntimeInterfaces;
          };
        }
        // (
          if isBgpRouter then
            {
              bgp = {
                asn = bgpSiteAsn;
                neighbors = (bgpNeighborsForNode nodeName) ++ ebgpNeighbors;
              };
            }
          else
            { }
        )
        // (
          if runtimeContainers != [ ] then
            {
              containers = runtimeContainers;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (nodeAttrs.egressIntent or null) then
            {
              egressIntent = nodeAttrs.egressIntent;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (nodeAttrs.forwardingResponsibility or null) then
            {
              forwardingResponsibility = nodeAttrs.forwardingResponsibility;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (nodeAttrs.routingAuthority or null) then
            {
              routingAuthority = nodeAttrs.routingAuthority;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (nodeAttrs.traversalParticipation or null) then
            {
              traversalParticipation = nodeAttrs.traversalParticipation;
            }
          else
            { }
        )
        // (
          if builtins.isList (nodeAttrs.forwardingFunctions or null) then
            {
              forwardingFunctions = nodeAttrs.forwardingFunctions;
            }
          else
            { }
        )
        // (
          if builtins.isList (nodeAttrs.attachments or null) then
            {
              attachments = nodeAttrs.attachments;
            }
          else
            { }
        )
        // (
          if builtins.isList (nodeAttrs.containers or null) then
            {
              declaredContainers = nodeAttrs.containers;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (nodeAttrs.networks or null) then
            {
              networks = nodeAttrs.networks;
            }
          else
            { }
        );
    in
    {
      name = targetId;
      value = value;
    };

  initialRuntimeTargets =
    builtins.seq
      _validateSiteRouting
      (builtins.listToAttrs (
        builtins.map
          buildRuntimeTarget
          (sortedNames nodes)
      ));

  defaultReachability =
    deriveDefaultReachability {
      inherit sitePath siteAttrs;
      transit = transitAttrs;
      runtimeTargets = initialRuntimeTargets;
    };

  accessAdvertisements =
    resolveAccessAdvertisements {
      inherit sitePath siteAttrs realizationIndex endpointInventoryIndex;
      runtimeTargets = defaultReachability.runtimeTargets;
    };

  firewallIntent =
    resolveFirewallIntent {
      inherit sitePath siteAttrs;
      runtimeTargets = defaultReachability.runtimeTargets;
    };

  policyEndpointBindings =
    resolvePolicyEndpointBindings {
      inherit sitePath siteAttrs attachments domains;
      runtimeTargets = defaultReachability.runtimeTargets;
    };

  runtimeTargets =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target = defaultReachability.runtimeTargets.${targetName};
          in
          {
            name = targetName;
            value =
              target
              // (
                if hasAttr targetName firewallIntent.natByTarget then
                  {
                    natIntent = firewallIntent.natByTarget.${targetName};
                  }
                else
                  { }
              )
              // (
                if hasAttr targetName firewallIntent.forwardingByTarget then
                  {
                    forwardingIntent = firewallIntent.forwardingByTarget.${targetName};
                  }
                else
                  { }
              )
              // (
                if hasAttr targetName accessAdvertisements then
                  {
                    advertisements = accessAdvertisements.${targetName};
                  }
                else
                  { }
              );
          })
        (sortedNames defaultReachability.runtimeTargets)
    );

  resolvedServices =
    builtins.map
      (serviceName: policyEndpointBindings.services.${serviceName})
      (sortedNames policyEndpointBindings.services);
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
  forwardingSemantics = defaultReachability.forwardingSemantics;
  overlays = overlayProvisioning;
  relations = policyEndpointBindings.relations;
  services = resolvedServices;
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
