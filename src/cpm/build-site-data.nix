{ lib, helpers, realizationIndex, endpointInventoryIndex, inventory ? { }, enterpriseRoot ? { } }:

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

  isGlobalIPv6Prefix = value:
    isNonEmptyString value
    && builtins.match ".*:.*" value != null
    && builtins.match "[Ff][Cc].*" value == null
    && builtins.match "[Ff][Dd].*" value == null
    && builtins.match "[Ff][Ee]80.*" value == null;

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

  mergeRoutes =
    base: extra: {
      ipv4 = listOrEmpty (base.ipv4 or [ ]) ++ listOrEmpty (extra.ipv4 or [ ]);
      ipv6 = listOrEmpty (base.ipv6 or [ ]) ++ listOrEmpty (extra.ipv6 or [ ]);
    };

  uniqueStrings =
    values:
    sortedNames (
      builtins.listToAttrs (
        builtins.map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter isNonEmptyString values)
      )
    );

  allSiteEntries =
    builtins.concatLists (
      builtins.map
        (enterpriseKey:
          let
            enterpriseValue =
              requireAttrs
                "forwardingModel.enterprise.${enterpriseKey}"
                (enterpriseRoot.${enterpriseKey} or null);
            siteRoot =
              requireAttrs
                "forwardingModel.enterprise.${enterpriseKey}.site"
                (enterpriseValue.site or null);
          in
          builtins.map
            (siteKey:
              let
                candidateSite =
                  requireAttrs
                    "forwardingModel.enterprise.${enterpriseKey}.site.${siteKey}"
                    siteRoot.${siteKey};
              in
              {
                enterpriseKey = enterpriseKey;
                siteKey = siteKey;
                site = candidateSite;
                siteId =
                  requireString
                    "forwardingModel.enterprise.${enterpriseKey}.site.${siteKey}.siteId"
                    (candidateSite.siteId or null);
                siteDisplayName =
                  requireString
                    "forwardingModel.enterprise.${enterpriseKey}.site.${siteKey}.siteName"
                    (candidateSite.siteName or null);
              })
            (sortedNames siteRoot))
        (sortedNames enterpriseRoot)
    );

  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);

  ipv4ToInt =
    octets:
    let
      a = builtins.elemAt octets 0;
      b = builtins.elemAt octets 1;
      c = builtins.elemAt octets 2;
      d = builtins.elemAt octets 3;
    in
    a * 16777216 + b * 65536 + c * 256 + d;

  ipv4NetworkBaseInt =
    { addrInt, prefixLen }:
    let
      hostBits = 32 - prefixLen;
      block = pow2 hostBits;
    in
    (builtins.div addrInt block) * block;

  cidrContainsAddress =
    cidr: address:
    let
      parsedCidr = ipam.splitCIDR cidr;
    in
    if parsedCidr == null then
      false
    else
      let
        cidrAddr = ipam.parseIPv4 parsedCidr.addr;
        addr = ipam.parseIPv4 address;
      in
      cidrAddr != null
      && addr != null
      && ipv4NetworkBaseInt {
        addrInt = ipv4ToInt addr;
        prefixLen = parsedCidr.prefixLen;
      }
      == ipv4NetworkBaseInt {
        addrInt = ipv4ToInt cidrAddr;
        prefixLen = parsedCidr.prefixLen;
      };

  failForwarding = path: message:
    throw "forwarding-model update required: ${path}: ${message}";

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
  siteAttrs = requireAttrs sitePath site;
  ownership = attrsOrEmpty (siteAttrs.ownership or null);

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
        canonicalRelations =
          if builtins.isList (contract.relations or null) then
            {
              relations = requireList "${sitePath}.communicationContract.relations" contract.relations;
            }
          else if builtins.isList (contract.allowedRelations or null) then
            {
              allowedRelations =
                requireList
                  "${sitePath}.communicationContract.allowedRelations"
                  contract.allowedRelations;
            }
          else
            { };
      in
      canonicalRelations
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
  inventoryEndpoints = attrsOrEmpty (inventoryAttrs.endpoints or null);

  serviceDefinitions =
    if communicationContract != null && builtins.isList (communicationContract.services or null) then
      builtins.listToAttrs (
        builtins.genList
          (idx:
            let
              servicePath = "${sitePath}.communicationContract.services[${toString idx}]";
              service = requireAttrs servicePath (builtins.elemAt communicationContract.services idx);
              serviceName = requireString "${servicePath}.name" (service.name or null);
            in
            {
              name = serviceName;
              value = service;
            })
          (builtins.length communicationContract.services)
      )
    else
      { };

  allowedRelations =
    if communicationContract != null && builtins.isList (communicationContract.relations or null) then
      communicationContract.relations
    else if communicationContract != null && builtins.isList (communicationContract.allowedRelations or null) then
      communicationContract.allowedRelations
    else
      [ ];

  relationEndpointMatchesTenant =
    tenantName: endpoint:
    if endpoint == "any" then
      true
    else if builtins.isString endpoint then
      endpoint == tenantName
    else if builtins.isList endpoint then
      lib.any (item: relationEndpointMatchesTenant tenantName item) endpoint
    else if builtins.isAttrs endpoint then
      let
        kind = endpoint.kind or null;
      in
      if kind == "tenant" then
        (endpoint.name or null) == tenantName
      else if kind == "tenant-set" && builtins.isList (endpoint.members or null) then
        builtins.elem tenantName endpoint.members
      else
        false
    else
      false;

  effectiveTrafficTypeForRelation =
    relation: serviceDef:
    let
      relationTrafficType = relation.trafficType or null;
      serviceTrafficType = serviceDef.trafficType or null;
    in
    if isNonEmptyString relationTrafficType then relationTrafficType else serviceTrafficType;

  providerAddressesForDnsService =
    providerName:
    let
      endpointPath = "inventory.endpoints.${providerName}";
      endpoint = attrsOrEmpty (inventoryEndpoints.${providerName} or null);
    in
    if endpoint == { } then
      failInventory
        endpointPath
        "DNS service provider '${providerName}' requires explicit inventory.endpoints.${providerName}.ipv4 and/or ipv6 for policy-derived DNS upstreams"
    else
      uniqueStrings (
        (if builtins.isList (endpoint.ipv4 or null) then requireStringList "${endpointPath}.ipv4" endpoint.ipv4 else [ ])
        ++ (if builtins.isList (endpoint.ipv6 or null) then requireStringList "${endpointPath}.ipv6" endpoint.ipv6 else [ ])
      );

  tenantPrefixesForName =
    tenantName:
    let
      tenantDef =
        lib.findFirst
          (tenant:
            builtins.isAttrs tenant
            && (tenant.name or null) == tenantName)
          null
          domains.tenants;
      tenantPath = "${sitePath}.domains.tenants.${tenantName}";
    in
    if tenantDef == null then
      [ ]
    else
      uniqueStrings (
        lib.optional (isNonEmptyString (tenantDef.ipv4 or null))
          (requireString "${tenantPath}.ipv4" tenantDef.ipv4)
        ++ lib.optional (isNonEmptyString (tenantDef.ipv6 or null))
          (requireString "${tenantPath}.ipv6" tenantDef.ipv6)
      );

  attachedNodeNamesForTenant =
    tenantName:
    uniqueStrings (
      (builtins.map
        (attachment:
          let
            attachmentAttrs = requireAttrs "${sitePath}.attachments[*]" attachment;
          in
          if
            (attachmentAttrs.kind or null) == "tenant"
            && (attachmentAttrs.name or null) == tenantName
            && isNonEmptyString (attachmentAttrs.unit or null)
          then
            attachmentAttrs.unit
          else
            "")
        attachments)
      ++ (
        builtins.map
          (nodeName:
            let
              nodePath = "${sitePath}.nodes.${nodeName}";
              nodeAttrs = requireAttrs nodePath nodes.${nodeName};
              attachedTenants =
                if builtins.isList (nodeAttrs.attachments or null) then
                  builtins.map
                    (attachment:
                      let
                        attachmentAttrs = requireAttrs "${nodePath}.attachments[*]" attachment;
                      in
                      if
                        (attachmentAttrs.kind or null) == "tenant"
                        && isNonEmptyString (attachmentAttrs.name or null)
                      then
                        attachmentAttrs.name
                      else
                        "")
                    nodeAttrs.attachments
                else
                  [ ];
            in
            if builtins.elem tenantName attachedTenants then nodeName else "")
          (sortedNames nodes)
      )
    );

  interfaceCidrsForNode =
    nodeName:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath nodes.${nodeName};
      nodeInterfaces = requireAttrs "${nodePath}.interfaces" (nodeAttrs.interfaces or null);
    in
    uniqueStrings (
      lib.concatMap
        (ifName:
          let
            iface = requireAttrs "${nodePath}.interfaces.${ifName}" nodeInterfaces.${ifName};
          in
          lib.optional (isNonEmptyString (iface.addr4 or null))
            (requireString "${nodePath}.interfaces.${ifName}.addr4" iface.addr4)
          ++ lib.optional (isNonEmptyString (iface.addr6 or null))
            (requireString "${nodePath}.interfaces.${ifName}.addr6" iface.addr6))
        (sortedNames nodeInterfaces)
    );

  consumerInterfaceCidrsForTenant =
    tenantName:
    uniqueStrings (lib.concatMap interfaceCidrsForNode (attachedNodeNamesForTenant tenantName));

  tenantNameForAddress =
    address:
    let
      matchingTenants =
        lib.filter
          (tenant:
            let
              tenantName = requireString "${sitePath}.domains.tenants[*].name" (tenant.name or null);
              tenantPath = "${sitePath}.domains.tenants.${tenantName}";
              prefixes =
                lib.optional (isNonEmptyString (tenant.ipv4 or null))
                  (requireString "${tenantPath}.ipv4" tenant.ipv4);
            in
            lib.any (prefix: cidrContainsAddress prefix address) prefixes)
          domains.tenants;
    in
    if builtins.length matchingTenants == 1 then
      (builtins.head matchingTenants).name
    else
      null;

  providerTenantsForServiceProvider =
    providerName:
    let
      ownershipMatches =
        if builtins.isList (ownership.endpoints or null) then
          lib.filter
            (endpoint:
              builtins.isAttrs endpoint
              && (endpoint.name or null) == providerName
              && isNonEmptyString (endpoint.tenant or null))
            ownership.endpoints
        else
          [ ];
      inventoryEndpoint = attrsOrEmpty (inventoryEndpoints.${providerName} or null);
      inventoryAddresses =
        uniqueStrings (
          (if builtins.isList (inventoryEndpoint.ipv4 or null) then
             requireStringList "inventory.endpoints.${providerName}.ipv4" inventoryEndpoint.ipv4
           else
             [ ])
        );
    in
    uniqueStrings (
      (map (endpoint: endpoint.tenant) ownershipMatches)
      ++ lib.filter (tenant: tenant != null) (map tenantNameForAddress inventoryAddresses)
    );

  tenantNamesForRelationEndpoint =
    endpoint:
    if endpoint == "any" then
      builtins.map (tenant: tenant.name) domains.tenants
    else if builtins.isString endpoint then
      [ endpoint ]
    else if builtins.isList endpoint then
      uniqueStrings (lib.concatMap tenantNamesForRelationEndpoint endpoint)
    else if builtins.isAttrs endpoint then
      let
        kind = endpoint.kind or null;
      in
      if kind == "tenant" && isNonEmptyString (endpoint.name or null) then
        [ endpoint.name ]
      else if kind == "tenant-set" && builtins.isList (endpoint.members or null) then
        requireStringList "${sitePath}.communicationContract.allowedRelations[*].from.members" endpoint.members
      else
        [ ]
    else
      [ ];

  policyDerivedDnsForwardersForTenants =
    tenantNames:
    uniqueStrings (
      lib.concatMap
        (tenantName:
          let
            allowedDnsServices =
              uniqueStrings (
                builtins.map
                  (relation:
                    let
                      serviceName = relation.to.name or null;
                    in
                    serviceName)
                  (
                    builtins.filter
                      (relation:
                        let
                          relationAttrs =
                            if builtins.isAttrs relation then
                              relation
                            else
                              { };
                          serviceName =
                            if
                              builtins.isAttrs (relationAttrs.to or null)
                              && builtins.isString (relationAttrs.to.name or null)
                            then
                              relationAttrs.to.name
                            else
                              null;
                          serviceDef =
                            if serviceName != null && hasAttr serviceName serviceDefinitions then
                              serviceDefinitions.${serviceName}
                            else
                              { };
                        in
                        (relationAttrs.action or "allow") == "allow"
                        && builtins.isAttrs (relationAttrs.to or null)
                        && (relationAttrs.to.kind or null) == "service"
                        && serviceName != null
                        && hasAttr serviceName serviceDefinitions
                        && effectiveTrafficTypeForRelation relationAttrs serviceDef == "dns"
                        && relationEndpointMatchesTenant tenantName (relationAttrs.from or null))
                      allowedRelations
                  )
              );
          in
          lib.concatMap
            (serviceName:
              let
                serviceDef = serviceDefinitions.${serviceName};
                providers =
                  if builtins.isList (serviceDef.providers or null) then
                    requireStringList
                      "${sitePath}.communicationContract.services.${serviceName}.providers"
                      serviceDef.providers
                  else
                    [ ];
              in
              lib.concatMap providerAddressesForDnsService providers)
            allowedDnsServices)
        tenantNames
    );

  policyDerivedDnsAllowFromForListeners =
    listenAddrs:
    let
      listenSet = uniqueStrings listenAddrs;
      serviceNames = sortedNames serviceDefinitions;
      hostedDnsServices =
        builtins.filter
          (serviceName:
            let
              serviceDef = serviceDefinitions.${serviceName};
              trafficType = serviceDef.trafficType or null;
              providers =
                if builtins.isList (serviceDef.providers or null) then
                  requireStringList
                    "${sitePath}.communicationContract.services.${serviceName}.providers"
                    serviceDef.providers
                else
                  [ ];
              providerAddresses = lib.concatMap providerAddressesForDnsService providers;
            in
            trafficType == "dns" && lib.any (addr: builtins.elem addr listenSet) providerAddresses)
          serviceNames;
    in
    uniqueStrings (
      lib.concatMap
        (serviceName:
          lib.concatMap
            (relation:
              let
                relationAttrs =
                  if builtins.isAttrs relation then
                    relation
                  else
                    { };
                relationServiceName =
                  if
                    builtins.isAttrs (relationAttrs.to or null)
                    && builtins.isString (relationAttrs.to.name or null)
                  then
                    relationAttrs.to.name
                  else
                    null;
              in
              if
                (relationAttrs.action or "allow") == "allow"
                && builtins.isAttrs (relationAttrs.to or null)
                && (relationAttrs.to.kind or null) == "service"
                && relationServiceName == serviceName
                && effectiveTrafficTypeForRelation relationAttrs serviceDefinitions.${serviceName} == "dns"
              then
                let
                  tenantNames = tenantNamesForRelationEndpoint (relationAttrs.from or null);
                in
                lib.concatMap
                  (tenantName:
                    (tenantPrefixesForName tenantName)
                    ++ (consumerInterfaceCidrsForTenant tenantName))
                  tenantNames
              else
                [ ])
            allowedRelations)
        hostedDnsServices
    );

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

            explicitOverlayNodeNames =
              lib.sort (a: b: a < b) (
                lib.unique (
                  (sortedNames overlayNodesCfg)
                  ++ (sortedNames overlayIpamNodesCfg)
                )
              );

            overlayNodeNames =
              lib.sort (a: b: a < b) (
                lib.unique (terminateOn ++ explicitOverlayNodeNames)
              );

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
                  overlayNodeNames
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
              // lib.optionalAttrs (ipamV4Prefix != null || ipamV6Prefix != null) {
                ipam =
                  lib.optionalAttrs (ipamV4Prefix != null) {
                    ipv4 =
                      { prefix = ipamV4Prefix; }
                      // lib.optionalAttrs (builtins.isInt (overlayIpamV4.perNodePrefixLength or null)) {
                        perNodePrefixLength = overlayIpamV4.perNodePrefixLength;
                      }
                      // lib.optionalAttrs (builtins.isInt (overlayIpamV4.offsetStart or null)) {
                        offsetStart = overlayIpamV4.offsetStart;
                      };
                  }
                  // lib.optionalAttrs (ipamV6Prefix != null) {
                    ipv6 =
                      { prefix = ipamV6Prefix; }
                      // lib.optionalAttrs (builtins.isInt (overlayIpamV6.perNodePrefixLength or null)) {
                        perNodePrefixLength = overlayIpamV6.perNodePrefixLength;
                      }
                      // lib.optionalAttrs (builtins.isInt (overlayIpamV6.offsetStart or null)) {
                        offsetStart = overlayIpamV6.offsetStart;
                      };
                  };
              }
              // lib.optionalAttrs (isNonEmptyString (cfg.provider or null)) { provider = cfg.provider; }
              // lib.optionalAttrs (builtins.isAttrs (cfg.nebula or null)) { nebula = cfg.nebula; };
          })
        overlayNames
    );

  resolvePeerSiteEntry =
    peerSite:
    lib.findFirst
      (
        entry:
        entry.siteId == peerSite
        || entry.siteDisplayName == peerSite
        || "${entry.enterpriseKey}.${entry.siteKey}" == peerSite
      )
      null
      allSiteEntries;

  transitEndpointAddressesByNodeForTransit =
    transitValue:
    builtins.foldl'
      (acc: adjacency:
        let
          endpoints =
            requireList "${sitePath}.transit.adjacencies[*].endpoints" (adjacency.endpoints or null);
          applyEndpoint =
            state: endpoint:
            let
              nodeName =
                requireString "${sitePath}.transit.adjacencies[*].endpoints[*].unit" (endpoint.unit or null);
              local = attrsOrEmpty (endpoint.local or null);
              existing =
                if builtins.hasAttr nodeName state then
                  state.${nodeName}
                else
                  { ipv4 = [ ]; ipv6 = [ ]; };
            in
            state
            // {
              ${nodeName} = {
                ipv4 =
                  if isNonEmptyString (local.ipv4 or null) then
                    uniqueStrings (existing.ipv4 ++ [ local.ipv4 ])
                  else
                    existing.ipv4;
                ipv6 =
                  if isNonEmptyString (local.ipv6 or null) then
                    uniqueStrings (existing.ipv6 ++ [ local.ipv6 ])
                  else
                    existing.ipv6;
              };
            };
        in
        builtins.foldl' applyEndpoint acc endpoints)
      { }
      (listOrEmpty (transitValue.adjacencies or null));

  overlayTransitEndpointAddressesByOverlay =
    builtins.listToAttrs (
      builtins.map
        (overlayName:
          let
            overlayCfg = attrsOrEmpty (overlayProvisioning.${overlayName} or null);
            peerSite = overlayCfg.peerSite or null;
            peerSiteEntry =
              if isNonEmptyString peerSite then
                resolvePeerSiteEntry peerSite
              else
                null;
            peerTransit =
              if peerSiteEntry == null then
                { }
              else
                attrsOrEmpty (peerSiteEntry.site.transit or null);
            peerDomains =
              if peerSiteEntry == null then
                { }
              else
                attrsOrEmpty (peerSiteEntry.site.domains or null);
            peerTenants =
              if builtins.isList (peerDomains.tenants or null) then
                peerDomains.tenants
              else
                [ ];
            peerPrefixes4 =
              uniqueStrings (
                builtins.filter isNonEmptyString (
                  builtins.map (tenant: (attrsOrEmpty tenant).ipv4 or null) peerTenants
                )
              );
            peerPrefixes6 =
              uniqueStrings (
                builtins.filter isNonEmptyString (
                  builtins.map (tenant: (attrsOrEmpty tenant).ipv6 or null) peerTenants
                )
              );
          in
          {
            name = overlayName;
            value = {
              peerSite = peerSite;
              byNode = transitEndpointAddressesByNodeForTransit peerTransit;
              peerPrefixes4 = peerPrefixes4;
              peerPrefixes6 = peerPrefixes6;
            };
          })
        overlayNames
    );

  buildOverlayTransitEndpointRoute =
    family: overlayName: peerSite: destination: destinationNode: gateway:
    {
      dst =
        if family == 4 then
          "${destination}/32"
        else
          "${destination}/128";
      intent = {
        kind = "overlay-reachability";
        source = "transit-endpoint";
        node = destinationNode;
      };
      proto = "overlay";
      overlay = overlayName;
      peerSite = peerSite;
    }
    // (
      if gateway == null then
        { }
      else if family == 4 then
        { via4 = gateway; }
      else
        { via6 = gateway; }
    );

  routeWithDstPresent =
    family: routes: destination:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.dst or null)
          == (if family == 4 then "${destination}/32" else "${destination}/128"))
      (listOrEmpty routes);

  routeWithExactDstPresent =
    routes: destination:
    builtins.any
      (route: builtins.isAttrs route && (route.dst or null) == destination)
      (listOrEmpty routes);

  routeWithDstAndGatewayPresent =
    family: routes: destination: gateway:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.dst or null) == destination
        && (
          if family == 4 then
            (route.via4 or null) == gateway
          else
            (route.via6 or null) == gateway
        ))
      (listOrEmpty routes);

  routeForExactDstWithGateway =
    family: routes: destination:
    lib.findFirst
      (route:
        builtins.isAttrs route
        && (route.dst or null) == destination
        && (
          if family == 4 then
            isNonEmptyString (route.via4 or null)
          else
            isNonEmptyString (route.via6 or null)
        ))
      null
      (listOrEmpty routes);

  familyPrefixes =
    family: prefixes:
    builtins.filter
      (prefix:
        if family == 4 then
          builtins.match ".*:.*" prefix == null
        else
          builtins.match ".*:.*" prefix != null)
      prefixes;

  routeGatewayForPrefix =
    family: routes: destinations:
    let
      matchingRoute =
        lib.findFirst
          (route:
            builtins.isAttrs route
            && builtins.elem (route.dst or null) destinations
            && (
              if family == 4 then
                isNonEmptyString (route.via4 or null)
              else
                isNonEmptyString (route.via6 or null)
            ))
          null
          (listOrEmpty routes);
    in
    if matchingRoute == null then
      null
    else if family == 4 then
      matchingRoute.via4
    else
      matchingRoute.via6;

  dnsServiceRouteSpecs =
    builtins.map
      (relation:
        let
          relationAttrs =
            if builtins.isAttrs relation then
              relation
            else
              { };
          serviceName = relationAttrs.to.name or null;
          serviceDef = serviceDefinitions.${serviceName};
          providers =
            if builtins.isList (serviceDef.providers or null) then
              requireStringList
                "${sitePath}.communicationContract.services.${serviceName}.providers"
                serviceDef.providers
            else
              [ ];
          providerTenants =
            uniqueStrings (lib.concatMap providerTenantsForServiceProvider providers);
          providerPrefixes =
            uniqueStrings (lib.concatMap tenantPrefixesForName providerTenants);
          consumerTenants = tenantNamesForRelationEndpoint (relationAttrs.from or null);
          consumerPrefixes =
            uniqueStrings (lib.concatMap tenantPrefixesForName consumerTenants);
        in
        {
          inherit serviceName;
          consumerPrefixes4 = familyPrefixes 4 consumerPrefixes;
          consumerPrefixes6 = familyPrefixes 6 consumerPrefixes;
          providerPrefixes4 = familyPrefixes 4 providerPrefixes;
          providerPrefixes6 = familyPrefixes 6 providerPrefixes;
        })
      (
        builtins.filter
          (relation:
            let
              relationAttrs =
                if builtins.isAttrs relation then
                  relation
                else
                  { };
              serviceName =
                if
                  builtins.isAttrs (relationAttrs.to or null)
                  && builtins.isString (relationAttrs.to.name or null)
                then
                  relationAttrs.to.name
                else
                  null;
              serviceDef =
                if serviceName != null && hasAttr serviceName serviceDefinitions then
                  serviceDefinitions.${serviceName}
                else
                  { };
            in
            (relationAttrs.action or "allow") == "allow"
            && builtins.isAttrs (relationAttrs.to or null)
            && (relationAttrs.to.kind or null) == "service"
            && serviceName != null
            && hasAttr serviceName serviceDefinitions
            && effectiveTrafficTypeForRelation relationAttrs serviceDef == "dns")
          allowedRelations
      );

  augmentDnsServiceRoutesForTarget =
    targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization"
          (target.effectiveRuntimeRealization or null);
      interfaces =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization.interfaces"
          (effective.interfaces or null);
      interfaceNames = sortedNames interfaces;
      isUpstreamSelectorTarget =
        let
          runtimeIfNames =
            builtins.map
              (
                ifName:
                requireString
                  "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName"
                  ((interfaces.${ifName} or { }).runtimeIfName or null)
              )
              interfaceNames;
          hasCoreIngress =
            lib.any (name: name == "core" || lib.hasPrefix "core-" name) runtimeIfNames;
          hasPolicyEgress =
            lib.any
              (name: lib.hasPrefix "pol-" name || lib.hasPrefix "policy-" name)
              runtimeIfNames;
        in
        hasCoreIngress && hasPolicyEgress;

      findSourceRouteForDestination =
        family: consumerInterfaceName: destination:
        let
          candidateInterfaceNames =
            builtins.filter (ifName: ifName != consumerInterfaceName) interfaceNames;
        in
        lib.findFirst
          (route: route != null)
          null
          (
            builtins.map
              (ifName:
                let
                  candidateIface =
                    requireAttrs
                      "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}"
                      interfaces.${ifName};
                  candidateRoutes = attrsOrEmpty (candidateIface.routes or null);
                  familyRoutes =
                    if family == 4 then
                      listOrEmpty (candidateRoutes.ipv4 or null)
                    else
                      listOrEmpty (candidateRoutes.ipv6 or null);
                in
                routeForExactDstWithGateway family familyRoutes destination)
              candidateInterfaceNames
          );

      updatedInterfaces =
        builtins.mapAttrs
          (ifName: iface:
            let
              routes = attrsOrEmpty (iface.routes or null);
              existingV4 = listOrEmpty (routes.ipv4 or null);
              existingV6 = listOrEmpty (routes.ipv6 or null);
              matchingSpecs =
                builtins.filter
                  (spec:
                    builtins.any
                      (destination: routeWithExactDstPresent existingV4 destination)
                      spec.consumerPrefixes4
                    || builtins.any
                      (destination: routeWithExactDstPresent existingV6 destination)
                      spec.consumerPrefixes6)
                  dnsServiceRouteSpecs;

              extraV4 =
                builtins.foldl'
                  (acc: spec:
                    builtins.foldl'
                      (inner: destination:
                        let
                          sourceRoute = findSourceRouteForDestination 4 ifName destination;
                          gateway = if sourceRoute == null then null else sourceRoute.via4 or null;
                          extraRoute =
                            if sourceRoute == null || !isNonEmptyString gateway then
                              null
                            else
                              sourceRoute
                              // {
                                intent = (attrsOrEmpty (sourceRoute.intent or null)) // {
                                  service = spec.serviceName;
                                };
                              };
                        in
                        if
                          extraRoute == null
                          || routeWithDstAndGatewayPresent 4 (existingV4 ++ inner) destination gateway
                        then
                          inner
                        else
                          inner ++ [ extraRoute ])
                      acc
                      spec.providerPrefixes4)
                  [ ]
                  matchingSpecs;

              extraV6 =
                builtins.foldl'
                  (acc: spec:
                    builtins.foldl'
                      (inner: destination:
                        let
                          sourceRoute = findSourceRouteForDestination 6 ifName destination;
                          gateway = if sourceRoute == null then null else sourceRoute.via6 or null;
                          extraRoute =
                            if sourceRoute == null || !isNonEmptyString gateway then
                              null
                            else
                              sourceRoute
                              // {
                                intent = (attrsOrEmpty (sourceRoute.intent or null)) // {
                                  service = spec.serviceName;
                                };
                              };
                        in
                        if
                          extraRoute == null
                          || routeWithDstAndGatewayPresent 6 (existingV6 ++ inner) destination gateway
                        then
                          inner
                        else
                          inner ++ [ extraRoute ])
                      acc
                      spec.providerPrefixes6)
                  [ ]
                  matchingSpecs;
            in
            if extraV4 == [ ] && extraV6 == [ ] then
              iface
            else
              iface
              // {
                routes =
                  routes
                  // {
                    ipv4 = existingV4 ++ extraV4;
                    ipv6 = existingV6 ++ extraV6;
                  };
              })
          interfaces;
    in
    if isUpstreamSelectorTarget then
      target
    else
      target
      // {
        effectiveRuntimeRealization =
          effective
          // {
            interfaces = updatedInterfaces;
          };
      };

  augmentOverlayTransitEndpointRoutesForTarget =
    targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization"
          (target.effectiveRuntimeRealization or null);
      interfaces =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization.interfaces"
          (effective.interfaces or null);
      updatedInterfaces =
        builtins.mapAttrs
          (_: iface:
            let
              backingRef = attrsOrEmpty (iface.backingRef or null);
              overlayName =
                if (backingRef.kind or null) == "overlay" && isNonEmptyString (backingRef.name or null) then
                  backingRef.name
                else
                  null;
              overlayTransit =
                if overlayName != null && builtins.hasAttr overlayName overlayTransitEndpointAddressesByOverlay then
                  overlayTransitEndpointAddressesByOverlay.${overlayName}
                else
                  null;
              routes = attrsOrEmpty (iface.routes or null);
              existingV4 = listOrEmpty (routes.ipv4 or null);
              existingV6 = listOrEmpty (routes.ipv6 or null);
              overlaysForInterface =
                if overlayName != null then
                  [ overlayName ]
                else
                  builtins.filter
                    (candidateOverlayName:
                      let
                        candidateOverlay =
                          attrsOrEmpty (overlayTransitEndpointAddressesByOverlay.${candidateOverlayName} or null);
                        peerPrefixes4 = listOrEmpty (candidateOverlay.peerPrefixes4 or null);
                        peerPrefixes6 = listOrEmpty (candidateOverlay.peerPrefixes6 or null);
                      in
                      builtins.any (dst: routeWithExactDstPresent existingV4 dst) peerPrefixes4
                      || builtins.any (dst: routeWithExactDstPresent existingV6 dst) peerPrefixes6)
                    overlayNames;
              overlayExtraRoutes =
                builtins.map
                  (candidateOverlayName:
                    let
                      candidateOverlay =
                        attrsOrEmpty (overlayTransitEndpointAddressesByOverlay.${candidateOverlayName} or null);
                      peerSite = candidateOverlay.peerSite or null;
                      byNode = attrsOrEmpty (candidateOverlay.byNode or null);
                      peerPrefixes4 = listOrEmpty (candidateOverlay.peerPrefixes4 or null);
                      peerPrefixes6 = listOrEmpty (candidateOverlay.peerPrefixes6 or null);
                      gateway4 =
                        if overlayName != null then
                          null
                        else
                          routeGatewayForPrefix 4 existingV4 peerPrefixes4;
                      gateway6 =
                        if overlayName != null then
                          null
                        else
                          routeGatewayForPrefix 6 existingV6 peerPrefixes6;
                      extraV4 =
                        if !isNonEmptyString peerSite then
                          [ ]
                        else
                          builtins.concatLists (
                            builtins.map
                              (nodeName:
                                let
                                  addresses = attrsOrEmpty (byNode.${nodeName} or null);
                                in
                                builtins.map
                                  (address:
                                    buildOverlayTransitEndpointRoute 4 candidateOverlayName peerSite address nodeName gateway4)
                                  (builtins.filter
                                    (address: !routeWithDstPresent 4 existingV4 address)
                                    (listOrEmpty (addresses.ipv4 or null))))
                              (sortedNames byNode)
                          );
                      extraV6 =
                        if !isNonEmptyString peerSite then
                          [ ]
                        else
                          builtins.concatLists (
                            builtins.map
                              (nodeName:
                                let
                                  addresses = attrsOrEmpty (byNode.${nodeName} or null);
                                in
                                builtins.map
                                  (address:
                                    buildOverlayTransitEndpointRoute 6 candidateOverlayName peerSite address nodeName gateway6)
                                  (builtins.filter
                                    (address: !routeWithDstPresent 6 existingV6 address)
                                    (listOrEmpty (addresses.ipv6 or null))))
                              (sortedNames byNode)
                          );
                    in
                    {
                      ipv4 = extraV4;
                      ipv6 = extraV6;
                    })
                  overlaysForInterface;
              extraV4 = builtins.concatLists (builtins.map (entry: entry.ipv4) overlayExtraRoutes);
              extraV6 = builtins.concatLists (builtins.map (entry: entry.ipv6) overlayExtraRoutes);
            in
            if overlaysForInterface == [ ] then
              iface
            else
              iface
              // {
                routes =
                  routes
                  // {
                    ipv4 = existingV4 ++ extraV4;
                    ipv6 = existingV6 ++ extraV6;
                  };
              })
          interfaces;
    in
    target
    // {
      effectiveRuntimeRealization =
        effective
        // {
          interfaces = updatedInterfaces;
        };
    };

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
        let
          interfaceRoutes = requireRoutes ifacePath (ifaceAttrs.routes or null);
          effectiveRoutes =
            if portBinding != null && builtins.isAttrs (portBinding.interfaceRoutes or null) then
              mergeRoutes interfaceRoutes portBinding.interfaceRoutes
            else
              interfaceRoutes;
        in
        {
          runtimeTarget = targetId;
          logicalNode = nodeName;
          sourceInterface = ifName;
          sourceKind = sourceKind;
          runtimeIfName = runtimeIfName;
          renderedIfName = runtimeIfName;
          addr4 = effectiveAddr4;
          addr6 = effectiveAddr6;
          routes = effectiveRoutes;
          backingRef = builtins.removeAttrs backingRef [ "linkKind" "upstreamAlias" ];
        }
        // (
          if portBinding != null && isNonEmptyString (portBinding.adapterName or null) then
            {
              adapterName = portBinding.adapterName;
            }
          else
            { }
        )
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
      routeIntentKind = r:
        if builtins.isAttrs (r.intent or null) then
          r.intent.kind or null
        else
          null;
      keep4 = r:
        let
          dst = r.dst or null;
          proto = r.proto or null;
          intentKind = routeIntentKind r;
        in
        builtins.isAttrs r
        && builtins.isString dst
        && (
          dst == "0.0.0.0/0"
          || proto == "uplink"
          || proto == "overlay"
          || intentKind == "overlay-reachability"
          || intentKind == "internal-reachability"
          || intentKind == "realized-interface-route"
          || isHostRoute4 dst
        );
      keep6 = r:
        let
          dst = r.dst or null;
          proto = r.proto or null;
          intentKind = routeIntentKind r;
        in
        builtins.isAttrs r
        && builtins.isString dst
        && (
          dst == "::/0"
          || proto == "uplink"
          || proto == "overlay"
          || intentKind == "overlay-reachability"
          || intentKind == "internal-reachability"
          || intentKind == "realized-interface-route"
          || isHostRoute6 dst
        );
    in
    {
      ipv4 = builtins.filter keep4 v4;
      ipv6 = builtins.filter keep6 v6;
    };

  normalizeDnsService = servicesPath: dnsValue:
    let
      dnsPath = "${servicesPath}.dns";
      dns = requireAttrs dnsPath dnsValue;

      normalizeStringList = fieldName:
        let
          path = "${dnsPath}.${fieldName}";
          value = dns.${fieldName} or [ ];
        in
        builtins.map
          (entry:
            let
              rendered = requireString "${path}[*]" entry;
            in
            if isNonEmptyString rendered then
              rendered
            else
              failInventory path "must not contain empty strings")
          (requireList path value);

      listen = normalizeStringList "listen";
      allowFrom = normalizeStringList "allowFrom";
      forwarders =
        if dns ? forwarders then
          normalizeStringList "forwarders"
        else if dns ? upstreams then
          normalizeStringList "upstreams"
        else
          [ ];

      _forwarderConflict =
        if dns ? forwarders && dns ? upstreams then
          failInventory dnsPath "must define only one of 'forwarders' or 'upstreams'"
        else
          true;

      localZones =
        let
          path = "${dnsPath}.localZones";
          value = dns.localZones or [ ];
        in
        builtins.map
          (
            entry:
            let
              zone = requireAttrs "${path}[*]" entry;
              name = requireString "${path}[*].name" (zone.name or null);
              zoneType =
                if isNonEmptyString (zone.type or null) then
                  zone.type
                else
                  "static";
            in
            if isNonEmptyString name then
              {
                inherit name;
                type = zoneType;
              }
            else
              failInventory "${path}[*].name" "must not be empty"
          )
          (requireList path value);

      localRecords =
        let
          path = "${dnsPath}.localRecords";
          value = dns.localRecords or [ ];
        in
        builtins.map
          (
            record:
            let
              recordPath = "${path}[*]";
              attrs = requireAttrs recordPath record;
              name = requireString "${recordPath}.name" (attrs.name or null);
              a =
                builtins.map
                  (entry:
                    let
                      rendered = requireString "${recordPath}.a[*]" entry;
                    in
                    if isNonEmptyString rendered then
                      rendered
                    else
                      failInventory "${recordPath}.a" "must not contain empty strings")
                  (requireList "${recordPath}.a" (attrs.a or [ ]));
              aaaa =
                builtins.map
                  (entry:
                    let
                      rendered = requireString "${recordPath}.aaaa[*]" entry;
                    in
                    if isNonEmptyString rendered then
                      rendered
                    else
                      failInventory "${recordPath}.aaaa" "must not contain empty strings")
                  (requireList "${recordPath}.aaaa" (attrs.aaaa or [ ]));
              _hasData =
                if a == [ ] && aaaa == [ ] then
                  failInventory recordPath "must define at least one of 'a' or 'aaaa'"
                else
                  true;
            in
            builtins.seq _hasData (
              { name = name; }
              // lib.optionalAttrs (a != [ ]) { a = a; }
              // lib.optionalAttrs (aaaa != [ ]) { aaaa = aaaa; }
            )
          )
          (requireList path value);
    in
    builtins.seq _forwarderConflict (
      { }
      // lib.optionalAttrs (listen != [ ]) { listen = listen; }
      // lib.optionalAttrs (allowFrom != [ ]) { allowFrom = allowFrom; }
      // lib.optionalAttrs (forwarders != [ ]) { forwarders = forwarders; }
      // lib.optionalAttrs (localZones != [ ]) { localZones = localZones; }
      // lib.optionalAttrs (localRecords != [ ]) { localRecords = localRecords; }
    );

  normalizeMdnsService = servicesPath: mdnsValue:
    let
      mdnsPath = "${servicesPath}.mdns";
      mdns = requireAttrs mdnsPath mdnsValue;

      normalizeStringList = fieldName:
        let
          path = "${mdnsPath}.${fieldName}";
          value = mdns.${fieldName} or [ ];
        in
        builtins.map
          (entry:
            let
              rendered = requireString "${path}[*]" entry;
            in
            if isNonEmptyString rendered then
              rendered
            else
              failInventory path "must not contain empty strings")
          (requireList path value);

      reflector =
        if builtins.isBool (mdns.reflector or null) then
          mdns.reflector
        else
          false;
      allowInterfaces = normalizeStringList "allowInterfaces";
      denyInterfaces = normalizeStringList "denyInterfaces";
      publish =
        if mdns ? publish then
          let
            publishPath = "${mdnsPath}.publish";
            publishAttrs = requireAttrs publishPath mdns.publish;
            boolField =
              fieldName:
              if builtins.isBool (publishAttrs.${fieldName} or null) then
                publishAttrs.${fieldName}
              else
                false;
          in
          { }
          // lib.optionalAttrs (publishAttrs ? enable) {
            enable = boolField "enable";
          }
          // lib.optionalAttrs (publishAttrs ? addresses) {
            addresses = boolField "addresses";
          }
          // lib.optionalAttrs (publishAttrs ? userServices) {
            userServices = boolField "userServices";
          }
          // lib.optionalAttrs (publishAttrs ? workstation) {
            workstation = boolField "workstation";
          }
          // lib.optionalAttrs (publishAttrs ? domain) {
            domain = boolField "domain";
          }
        else
          { };
    in
    {
      inherit reflector;
    }
    // lib.optionalAttrs (allowInterfaces != [ ]) { allowInterfaces = allowInterfaces; }
    // lib.optionalAttrs (denyInterfaces != [ ]) { denyInterfaces = denyInterfaces; }
    // lib.optionalAttrs (publish != { }) { publish = publish; };

  normalizeRuntimeServices = targetDef:
    let
      servicesPath = "${targetDef.nodePath}.services";
      services = requireAttrs servicesPath (targetDef.node.services or null);
      serviceNames = sortedNames services;
    in
    builtins.listToAttrs (
      builtins.map
        (serviceName: {
          name = serviceName;
          value =
            if serviceName == "dns" then
              normalizeDnsService servicesPath services.${serviceName}
            else if serviceName == "mdns" then
              normalizeMdnsService servicesPath services.${serviceName}
            else
              services.${serviceName};
        })
        serviceNames
    );

  tenantAttachmentsForNode =
    nodePath: nodeName: nodeAttrs:
    uniqueStrings (
      (builtins.map
        (attachment:
          let
            attachmentAttrs = requireAttrs "${sitePath}.attachments[*]" attachment;
          in
          if
            (attachmentAttrs.kind or null) == "tenant"
            && (attachmentAttrs.unit or null) == nodeName
            && isNonEmptyString (attachmentAttrs.name or null)
          then
            attachmentAttrs.name
          else
            "")
        attachments)
      ++ (
        if builtins.isList (nodeAttrs.attachments or null) then
          builtins.map
            (attachment:
              let
                attachmentAttrs = requireAttrs "${nodePath}.attachments[*]" attachment;
              in
              if
                (attachmentAttrs.kind or null) == "tenant"
                && isNonEmptyString (attachmentAttrs.name or null)
              then
                attachmentAttrs.name
              else
                "")
            nodeAttrs.attachments
        else
          [ ]
      )
    );

  resolveRuntimeServices =
    {
      nodePath,
      nodeName,
      nodeAttrs,
      targetDef,
    }:
    let
      normalized = normalizeRuntimeServices targetDef;
      dnsService = attrsOrEmpty (normalized.dns or null);
      explicitForwarders =
        if builtins.isList (dnsService.forwarders or null) then
          requireStringList "${targetDef.nodePath}.services.dns.forwarders" dnsService.forwarders
        else
          [ ];
      explicitAllowFrom =
        if builtins.isList (dnsService.allowFrom or null) then
          requireStringList "${targetDef.nodePath}.services.dns.allowFrom" dnsService.allowFrom
        else
          [ ];
      listenAddresses =
        if builtins.isList (dnsService.listen or null) then
          requireStringList "${targetDef.nodePath}.services.dns.listen" dnsService.listen
        else
          [ ];
      tenantNames = tenantAttachmentsForNode nodePath nodeName nodeAttrs;
      derivedForwarders = policyDerivedDnsForwardersForTenants tenantNames;
      derivedAllowFrom =
        if builtins.isList (dnsService.listen or null) then
          policyDerivedDnsAllowFromForListeners dnsService.listen
        else
          [ ];
      mergedForwarders =
        if derivedForwarders == [ ] then
          explicitForwarders
        else
          builtins.filter
            (addr: !(builtins.elem addr listenAddresses))
            (uniqueStrings (derivedForwarders ++ explicitForwarders));
      mergedAllowFrom =
        if derivedAllowFrom == [ ] then
          explicitAllowFrom
        else
          uniqueStrings (explicitAllowFrom ++ derivedAllowFrom);
    in
    normalized
    // lib.optionalAttrs (dnsService != { }) {
      dns =
        dnsService
        // lib.optionalAttrs (mergedAllowFrom != [ ]) {
          allowFrom = mergedAllowFrom;
        }
        // lib.optionalAttrs (mergedForwarders != [ ]) {
          forwarders = mergedForwarders;
        };
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

      runtimeServices =
        if realizedTarget && builtins.isAttrs (targetDef.node.services or null) then
          resolveRuntimeServices {
            inherit nodePath;
            inherit nodeName nodeAttrs targetDef;
          }
        else
          null;

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
        )
        // (
          if runtimeServices != null then
            {
              services = runtimeServices;
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

  runtimeTargetsWithOverlayTransitEndpointRoutes =
    builtins.listToAttrs (
      builtins.map
        (targetName: {
          name = targetName;
          value =
            augmentDnsServiceRoutesForTarget
              targetName
              (
                augmentOverlayTransitEndpointRoutesForTarget
                  targetName
                  defaultReachability.runtimeTargets.${targetName}
              );
        })
        (sortedNames defaultReachability.runtimeTargets)
    );

  accessAdvertisements =
    resolveAccessAdvertisements {
      inherit sitePath siteAttrs realizationIndex endpointInventoryIndex;
      runtimeTargets = runtimeTargetsWithOverlayTransitEndpointRoutes;
    };

  firewallIntent =
    resolveFirewallIntent {
      inherit sitePath siteAttrs;
      runtimeTargets = runtimeTargetsWithOverlayTransitEndpointRoutes;
    };

  policyEndpointBindings =
    resolvePolicyEndpointBindings {
      inherit sitePath siteAttrs attachments domains;
      runtimeTargets = runtimeTargetsWithOverlayTransitEndpointRoutes;
    };

  runtimeTargets =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target = runtimeTargetsWithOverlayTransitEndpointRoutes.${targetName};
            hasAccessAdvertisements = hasAttr targetName accessAdvertisements;
            advertisedGlobalIPv6Prefixes =
              if !hasAccessAdvertisements then
                [ ]
              else
                builtins.filter
                  isGlobalIPv6Prefix
                  (
                    builtins.concatLists (
                      builtins.map
                        (entry: entry.prefixes or [ ])
                        (accessAdvertisements.${targetName}.ipv6Ra or [ ])
                    )
                  );
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
                if advertisedGlobalIPv6Prefixes != [ ] then
                  {
                    advertisements = accessAdvertisements.${targetName};
                    externalValidation = {
                      delegatedPrefixSecretName = "access-node-ipv6-prefix-${targetName}";
                      delegatedPrefixSecretPath = "/run/secrets/access-node-ipv6-prefix-${targetName}";
                      delegatedPrefixes = advertisedGlobalIPv6Prefixes;
                    };
                  }
                else if hasAccessAdvertisements then
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
      (
        serviceName:
        let
          resolvedService = policyEndpointBindings.services.${serviceName};
          providerNames =
            if builtins.isList (resolvedService.providers or null) then
              requireStringList "${sitePath}.services.${serviceName}.providers" resolvedService.providers
            else
              [ ];
        in
        resolvedService
        // {
          name = serviceName;
          providerTenants = uniqueStrings (
            lib.concatMap providerTenantsForServiceProvider providerNames
          );
        }
      )
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
