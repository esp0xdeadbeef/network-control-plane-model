{ lib, helpers, realizationIndex, endpointInventoryIndex }:

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
        if portBinding != null && isNonEmptyString (portBinding.interfaceAddr4 or null) then
          portBinding.interfaceAddr4
        else
          ifaceAttrs.addr4 or null;

      effectiveAddr6 =
        if portBinding != null && isNonEmptyString (portBinding.interfaceAddr6 or null) then
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
              hostUplink = {
                name = validatedHostUplink.uplinkName or null;
                bridge = validatedHostUplink.bridge or null;
              };
            }
            // (
              if builtins.isAttrs (validatedHostUplink.ipv4 or null) then
                { ipv4 = validatedHostUplink.ipv4; }
              else
                { }
            )
            // (
              if builtins.isAttrs (validatedHostUplink.ipv6 or null) then
                { ipv6 = validatedHostUplink.ipv6; }
              else
                { }
            )
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
              hostUplink = {
                name = validatedHostUplink.uplinkName or null;
                bridge = validatedHostUplink.bridge or null;
              };
            }
            // (
              if builtins.isAttrs (validatedHostUplink.ipv4 or null) then
                { ipv4 = validatedHostUplink.ipv4; }
              else
                { }
            )
            // (
              if builtins.isAttrs (validatedHostUplink.ipv6 or null) then
                { ipv6 = validatedHostUplink.ipv6; }
              else
                { }
            )
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

  buildRuntimeTarget = nodeName:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath nodes.${nodeName};

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

      value =
        {
          logicalNode = logical;
          role = nodeAttrs.role or null;
          placement = placement;
          effectiveRuntimeRealization = {
            loopback = {
              addr4 = requireString "${nodePath}.loopback.ipv4" (loopback.ipv4 or null);
              addr6 = requireString "${nodePath}.loopback.ipv6" (loopback.ipv6 or null);
            };
            interfaces = runtimeInterfaces;
          };
        }
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
              containers = nodeAttrs.containers;
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
    builtins.listToAttrs (
      builtins.map
        buildRuntimeTarget
        (sortedNames nodes)
    );

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
  siteId = requireString "${sitePath}.siteId" (siteAttrs.siteId or null);
  siteName = requireString "${sitePath}.siteName" (siteAttrs.siteName or null);
  policyNodeName = requireString "${sitePath}.policyNodeName" (siteAttrs.policyNodeName or null);
  upstreamSelectorNodeName = requireString "${sitePath}.upstreamSelectorNodeName" (siteAttrs.upstreamSelectorNodeName or null);
  coreNodeNames = requireStringList "${sitePath}.coreNodeNames" (siteAttrs.coreNodeNames or null);
  uplinkCoreNames = requireStringList "${sitePath}.uplinkCoreNames" (siteAttrs.uplinkCoreNames or null);
  uplinkNames = requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);
  attachments = attachments;
  domains = domainsValue;
  tenantPrefixOwners = tenantPrefixOwners;
  transit = transitAttrs;
  runtimeTargets = runtimeTargets;
  forwardingSemantics = defaultReachability.forwardingSemantics;
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
