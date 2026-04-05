{ lib, helpers, realizationIndex }:

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
    sortedNames;

  deriveDefaultReachability =
    import ./default-reachability-model.nix {
      inherit helpers;
    };

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

  policyInterfaceTags =
    if builtins.isAttrs (siteAttrs.policy or null) then
      let
        policy = requireAttrs "${sitePath}.policy" siteAttrs.policy;
      in
      if builtins.isAttrs (policy.interfaceTags or null) then
        policy.interfaceTags
      else
        null
    else
      null;

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
          addr4 = ifaceAttrs.addr4 or null;
          addr6 = ifaceAttrs.addr6 or null;
          routes = requireRoutes ifacePath (ifaceAttrs.routes or null);
          backingRef = builtins.removeAttrs backingRef [ "linkKind" "upstreamAlias" ];
        }
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

      wanIntent = {
        ipv4 =
          if builtins.isList (uplinkAttrs.ipv4 or null) then
            builtins.filter isNonEmptyString uplinkAttrs.ipv4
          else
            [ ];
        ipv6 =
          if builtins.isList (uplinkAttrs.ipv6 or null) then
            builtins.filter isNonEmptyString uplinkAttrs.ipv6
          else
            [ ];
      };

      baseValue =
        {
          runtimeTarget = targetId;
          logicalNode = nodeName;
          sourceInterface = uplinkName;
          sourceKind = "wan";
          runtimeIfName = runtimeIfName;
          renderedIfName = runtimeIfName;
          addr4 = null;
          addr6 = null;
          routes = {
            ipv4 = [ ];
            ipv6 = [ ];
          };
          backingRef = {
            kind = "link";
            id = "uplink::${enterpriseName}.${siteName}::${uplinkName}";
            name = uplinkName;
          };
          upstream = uplinkName;
          wan = wanIntent;
        }
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
        value = baseValue;
      };

  buildTargetInterfaces = {
    nodeName,
    node,
    portBindings,
    targetHostName,
    targetId,
    realizedTarget
  }:
    let
      interfaces = requireAttrs "${sitePath}.nodes.${nodeName}.interfaces" (node.interfaces or null);
      interfaceNames = sortedNames interfaces;

      uplinks =
        if builtins.isAttrs (node.uplinks or null) then
          node.uplinks
        else
          { };

      entries =
        (builtins.map
          (ifName:
            buildExplicitInterfaceEntry {
              inherit nodeName ifName portBindings targetHostName targetId realizedTarget;
              iface = interfaces.${ifName};
            })
          interfaceNames)
        ++
        (builtins.map
          (uplinkName:
            buildSyntheticUplinkInterfaceEntry {
              inherit nodeName portBindings targetHostName targetId realizedTarget;
              uplinkName = uplinkName;
              uplinkValue = uplinks.${uplinkName};
            })
          (sortedNames uplinks));
    in
    ensureUniqueEntries "${sitePath}.nodes.${nodeName}.effectiveRuntimeRealization.interfaces" entries;

  canonicalTransit =
    let
      adjacenciesRaw = requireList "${sitePath}.transit.adjacencies" (transitAttrs.adjacencies or null);
      ordering = requireStringList "${sitePath}.transit.ordering" (transitAttrs.ordering or null);

      adjacencyLookup =
        ensureUniqueEntries
          "${sitePath}.transit.adjacencies"
          (
            builtins.genList
              (idx:
                let
                  adjacencyPath = "${sitePath}.transit.adjacencies[${toString idx}]";
                  adjacency = requireAttrs adjacencyPath (builtins.elemAt adjacenciesRaw idx);
                  id = requireString "${adjacencyPath}.id" (adjacency.id or null);
                  _kind = requireString "${adjacencyPath}.kind" (adjacency.kind or null);
                  _endpoints = requireList "${adjacencyPath}.endpoints" (adjacency.endpoints or null);
                in
                {
                  name = id;
                  value = adjacency;
                })
              (builtins.length adjacenciesRaw)
          );
    in
    {
      inherit ordering;
      adjacencies =
        builtins.map
          (adjacencyId:
            if hasAttr adjacencyId adjacencyLookup then
              adjacencyLookup.${adjacencyId}
            else
              failForwarding
                "${sitePath}.transit.ordering"
                "input contract failure: ${sitePath}.transit.ordering references unknown adjacency id '${adjacencyId}'")
          ordering;
    };

  buildRuntimeTarget = nodeName: nodeValue:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      node = requireAttrs nodePath nodeValue;

      logical = {
        enterprise = enterpriseName;
        site = siteName;
        name = nodeName;
      };

      key = logicalKey logical;

      targetDef =
        if hasAttr key realizationIndex.byLogical then
          realizationIndex.targetDefs.${realizationIndex.byLogical.${key}}
        else
          null;

      targetId =
        if targetDef == null then
          nodeName
        else
          targetDef.targetName;

      realizedTarget = targetDef != null;

      targetHostName =
        if targetDef == null then
          null
        else
          requireString "${targetDef.nodePath}.host" (targetDef.node.host or null);

      placement =
        if targetDef == null then
          {
            kind = "logical-node";
            runtimeTargetId = targetId;
          }
        else
          {
            kind = "inventory-realization";
            runtimeTargetId = targetId;
            host = targetHostName;
            platform = requireString "${targetDef.nodePath}.platform" (targetDef.node.platform or null);
          }
          // (
            if isNonEmptyString (targetDef.node.container or null) then
              {
                container = targetDef.node.container;
              }
            else
              { }
          )
          // (
            if isNonEmptyString (targetDef.node.isolation or null) then
              {
                isolation = targetDef.node.isolation;
              }
            else
              { }
          );

      loopback = requireAttrs "${nodePath}.loopback" (node.loopback or null);
    in
    {
      name = targetId;
      value =
        {
          runtimeTargetId = targetId;
          role = node.role or null;
          logicalNode = logical;
          placement = placement;
          effectiveRuntimeRealization = {
            loopback = {
              addr4 = requireString "${nodePath}.loopback.ipv4" (loopback.ipv4 or null);
              addr6 = requireString "${nodePath}.loopback.ipv6" (loopback.ipv6 or null);
            };
            interfaces =
              buildTargetInterfaces {
                inherit nodeName node targetHostName targetId realizedTarget;
                portBindings =
                  if targetDef == null then
                    {
                      byLink = { };
                      byLogicalInterface = { };
                      byUplink = { };
                    }
                  else
                    targetDef.portBindings;
              };
          };
        }
        // (
          if builtins.isList (node.containers or null) then
            {
              availableContainers = node.containers;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (node.egressIntent or null) then
            {
              egressIntent = node.egressIntent;
            }
          else
            { }
        )
        // (
          if builtins.isList (node.forwardingFunctions or null) then
            {
              forwardingFunctions = node.forwardingFunctions;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (node.forwardingResponsibility or null) then
            {
              forwardingResponsibility = node.forwardingResponsibility;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (node.routingAuthority or null) then
            {
              routingAuthority = node.routingAuthority;
            }
          else
            { }
        )
        // (
          if builtins.isAttrs (node.traversalParticipation or null) then
            {
              traversalParticipation = node.traversalParticipation;
            }
          else
            { }
        );
    };

  baseRuntimeTargets =
    ensureUniqueEntries
      "${sitePath}.runtimeTargets"
      (
        builtins.map
          (nodeName: buildRuntimeTarget nodeName nodes.${nodeName})
          (sortedNames nodes)
      );

  defaultReachabilityProjection =
    deriveDefaultReachability {
      inherit sitePath siteAttrs;
      transit = canonicalTransit;
      runtimeTargets = baseRuntimeTargets;
    };
in
{
  siteId = requireString "${sitePath}.siteId" (siteAttrs.siteId or null);
  siteName = requireString "${sitePath}.siteName" (siteAttrs.siteName or null);
  attachments = attachments;
  policyNodeName = requireString "${sitePath}.policyNodeName" (siteAttrs.policyNodeName or null);
  upstreamSelectorNodeName =
    requireString "${sitePath}.upstreamSelectorNodeName" (siteAttrs.upstreamSelectorNodeName or null);
  coreNodeNames = requireStringList "${sitePath}.coreNodeNames" (siteAttrs.coreNodeNames or null);
  uplinkCoreNames = requireStringList "${sitePath}.uplinkCoreNames" (siteAttrs.uplinkCoreNames or null);
  uplinkNames = requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);
  domains = domains;
  tenantPrefixOwners = tenantPrefixOwners;
  transit = canonicalTransit;
  runtimeTargets = defaultReachabilityProjection.runtimeTargets;
}
// (
  if communicationContract != null then
    {
      inherit communicationContract;
    }
  else
    { }
)
// (
  if policyInterfaceTags != null then
    {
      policy = {
        interfaceTags = policyInterfaceTags;
      };
    }
  else
    { }
)
// (
  if builtins.isAttrs (siteAttrs.egressIntent or null) then
    {
      egressIntent = siteAttrs.egressIntent;
    }
  else
    { }
)
// (
  if builtins.isList (siteAttrs.services or null) then
    {
      services = siteAttrs.services;
    }
  else
    { }
)
// (
  if builtins.isAttrs defaultReachabilityProjection.forwardingSemantics then
    {
      forwardingSemantics = defaultReachabilityProjection.forwardingSemantics;
    }
  else if builtins.isAttrs (siteAttrs.forwardingSemantics or null) then
    {
      forwardingSemantics = siteAttrs.forwardingSemantics;
    }
  else
    { }
)
