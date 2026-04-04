{ lib, helpers, realizationIndex }:

{ enterpriseName, siteName, site }:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    isNonEmptyString
    logicalKey
    renderValue
    requireAttrs
    requireList
    requireRoutes
    requireString
    requireStringList
    sortedNames;

  warnWithContext = message: context:
    builtins.trace
      "migration warning: ${message}\n--- offending input context ---\n${renderValue context}"
      true;

  sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
  siteAttrs = requireAttrs sitePath site;

  tenantPrefixOwners =
    requireAttrs "${sitePath}.tenantPrefixOwners" (siteAttrs.tenantPrefixOwners or null);

  buildSiteLinks =
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
        })
      (requireAttrs "${sitePath}.links" (siteAttrs.links or null));

  siteLinks = buildSiteLinks;

  attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);

  attachmentLookup =
    let
      entries =
        builtins.genList
          (idx:
            let
              path = "${sitePath}.attachments[${toString idx}]";
              attachment = requireAttrs path (builtins.elemAt attachments idx);
              kind = requireString "${path}.kind" (attachment.kind or null);
              name = requireString "${path}.name" (attachment.name or null);
              unit = requireString "${path}.unit" (attachment.unit or null);
            in
            {
              name = "${unit}|${kind}|${name}";
              value = {
                kind = kind;
                name = name;
                unit = unit;
                id = "attachment::${unit}::${kind}::${name}";
              };
            })
          (builtins.length attachments);
    in
    ensureUniqueEntries "${sitePath}.attachments" entries;

  resolveBackingRef = nodeName: ifName: iface:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      kind = requireString "${ifacePath}.kind" (iface.kind or null);

      linkName =
        if isNonEmptyString (iface.link or null) then
          iface.link
        else
          null;

      tenantName =
        if isNonEmptyString (iface.tenant or null) then
          iface.tenant
        else
          null;

      overlayName =
        if isNonEmptyString (iface.overlay or null) then
          iface.overlay
        else
          null;

      legacyTenantLinkWarning =
        if kind == "tenant" && linkName != null then
          warnWithContext
            "tenant interface declares legacy link field; keeping attachment-backed behavior"
            {
              site = sitePath;
              node = nodeName;
              interfaceKey = ifName;
              interfaceDefinition = iface;
            }
        else
          true;

      legacyOverlayLinkWarning =
        if kind == "overlay" && linkName != null then
          warnWithContext
            "overlay interface declares legacy link field; keeping overlay-backed behavior"
            {
              site = sitePath;
              node = nodeName;
              interfaceKey = ifName;
              interfaceDefinition = iface;
            }
        else
          true;

      linkCandidate =
        if kind == "tenant" || kind == "overlay" || linkName == null then
          null
        else if hasAttr linkName siteLinks then
          let
            link = siteLinks.${linkName};
          in
          {
            kind = "link";
            id = requireString "${sitePath}.links.${linkName}.id" (link.id or null);
            name = linkName;
            linkKind = requireString "${sitePath}.links.${linkName}.kind" (link.kind or null);
          }
        else
          throw "runtime realization failure: ${ifacePath}.link references unknown link '${linkName}'";

      attachmentCandidate =
        if kind != "tenant" then
          null
        else
          let
            tenant = requireString "${ifacePath}.tenant" tenantName;
            attachmentKey = "${nodeName}|tenant|${tenant}";
          in
          if hasAttr attachmentKey attachmentLookup then
            let
              attachment = attachmentLookup.${attachmentKey};
            in
            {
              kind = "attachment";
              id = attachment.id;
              name = attachment.name;
            }
          else
            throw "runtime realization failure: ${ifacePath} could not resolve tenant attachment '${tenant}'";

      overlayCandidate =
        if kind != "overlay" then
          null
        else
          let
            resolvedOverlayName = requireString "${ifacePath}.overlay" overlayName;
          in
          {
            kind = "overlay";
            id = "overlay::${enterpriseName}.${siteName}::${resolvedOverlayName}";
            name = resolvedOverlayName;
          };

      candidates =
        builtins.filter
          (candidate: candidate != null)
          [
            linkCandidate
            attachmentCandidate
            overlayCandidate
          ];
    in
    builtins.seq
      legacyTenantLinkWarning
      (builtins.seq
        legacyOverlayLinkWarning
        (
          if builtins.length candidates != 1 then
            throw "runtime realization failure: ${ifacePath} must resolve to exactly one explicit backing reference"
          else
            builtins.elemAt candidates 0
        ));

  buildInterfaceEntry = { nodeName, ifName, iface, portLinks, targetId, realizedTarget }:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      ifaceAttrs = requireAttrs ifacePath iface;
      backingRef = resolveBackingRef nodeName ifName ifaceAttrs;
      sourceKind = requireString "${ifacePath}.kind" (ifaceAttrs.kind or null);
      sourceIfName = requireString "${ifacePath}.interface" (ifaceAttrs.interface or null);

      requiresExplicitPortRealization =
        realizedTarget
        && (backingRef.kind or null) == "link"
        && (backingRef.linkKind or null) == "p2p";

      portLink =
        if requiresExplicitPortRealization then
          if hasAttr backingRef.id portLinks then
            portLinks.${backingRef.id}
          else if hasAttr backingRef.name portLinks then
            portLinks.${backingRef.name}
          else
            throw "runtime realization failure: ${ifacePath} on realized target '${targetId}' requires explicit port realization for backing link '${backingRef.id}'"
        else if realizedTarget && (backingRef.kind or null) == "link" then
          if hasAttr backingRef.id portLinks then
            portLinks.${backingRef.id}
          else if hasAttr backingRef.name portLinks then
            portLinks.${backingRef.name}
          else
            null
        else
          null;

      runtimeIfName =
        if portLink != null then
          portLink.runtimeIfName
        else
          sourceIfName;

      hostUplink =
        if portLink != null && builtins.isAttrs (portLink.hostUplink or null) then
          portLink.hostUplink
        else
          null;

      wanInventoryExtras =
        if sourceKind == "wan" && hostUplink != null then
          {
            hostUplink = {
              name = hostUplink.uplinkName or null;
              bridge = hostUplink.bridge or null;
            };
          }
          // (
            if builtins.isAttrs (hostUplink.ipv4 or null) then
              { ipv4 = hostUplink.ipv4; }
            else
              { }
          )
          // (
            if builtins.isAttrs (hostUplink.ipv6 or null) then
              { ipv6 = hostUplink.ipv6; }
            else
              { }
          )
        else
          { };

      wanModelExtras =
        (if sourceKind == "wan" && isNonEmptyString (ifaceAttrs.upstream or null) then
          {
            upstream = ifaceAttrs.upstream;
          }
        else
          { })
        // (if sourceKind == "wan" && builtins.isAttrs (ifaceAttrs.wan or null) then
          {
            wan = ifaceAttrs.wan;
          }
        else
          { });
    in
    {
      name = ifName;
      value =
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
          backingRef =
            if (backingRef.kind or null) == "link" then
              builtins.removeAttrs backingRef [ "linkKind" ]
            else
              backingRef;
        }
        // wanModelExtras
        // wanInventoryExtras;
    };

  buildTargetInterfaces = { nodeName, node, portLinks, targetId, realizedTarget }:
    let
      interfaces = requireAttrs "${sitePath}.nodes.${nodeName}.interfaces" (node.interfaces or null);
      entries =
        builtins.map
          (ifName:
            buildInterfaceEntry {
              nodeName = nodeName;
              ifName = ifName;
              iface = interfaces.${ifName};
              portLinks = portLinks;
              targetId = targetId;
              realizedTarget = realizedTarget;
            })
          (sortedNames interfaces);
    in
    builtins.listToAttrs entries;

  buildCanonicalTransit =
    let
      transitPath = "${sitePath}.transit";
      transitAttrs = requireAttrs transitPath (siteAttrs.transit or null);
      adjacencies = requireList "${transitPath}.adjacencies" (transitAttrs.adjacencies or null);
      ordering = requireStringList "${transitPath}.ordering" (transitAttrs.ordering or null);

      adjacencyLookup =
        ensureUniqueEntries
          "${transitPath}.adjacencies[*].id"
          (
            builtins.genList
              (idx:
                let
                  adjacencyPath = "${transitPath}.adjacencies[${toString idx}]";
                  adjacency = requireAttrs adjacencyPath (builtins.elemAt adjacencies idx);
                  adjacencyId = requireString "${adjacencyPath}.id" (adjacency.id or null);
                  linkName =
                    if isNonEmptyString (adjacency.link or null) then
                      adjacency.link
                    else
                      null;
                in
                {
                  name = adjacencyId;
                  value =
                    {
                      id = adjacencyId;
                      kind = requireString "${adjacencyPath}.kind" (adjacency.kind or null);
                      endpoints = requireList "${adjacencyPath}.endpoints" (adjacency.endpoints or null);
                    }
                    // (
                      if linkName != null then
                        {
                          link = linkName;
                          linkId = requireString "${sitePath}.links.${linkName}.id" (siteLinks.${linkName}.id or null);
                        }
                      else
                        { }
                    )
                    // (
                      if isNonEmptyString (adjacency.name or null) then
                        {
                          name = adjacency.name;
                        }
                      else
                        { }
                    )
                    // (
                      if adjacency ? routingParticipation then
                        {
                          routingParticipation = adjacency.routingParticipation;
                        }
                      else
                        { }
                    );
                })
              (builtins.length adjacencies)
          );
    in
    {
      ordering = ordering;
      adjacencies =
        builtins.map
          (adjacencyId: adjacencyLookup.${adjacencyId})
          ordering;
    };

  buildRuntimeTarget = nodeName: node:
    let
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

      nodeContainers =
        if builtins.isList (node.containers or null) then
          node.containers
        else
          null;

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
            host = requireString "${targetDef.nodePath}.host" (targetDef.node.host or null);
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

      loopback = requireAttrs "${sitePath}.nodes.${nodeName}.loopback" (node.loopback or null);
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
              addr4 = requireString "${sitePath}.nodes.${nodeName}.loopback.ipv4" (loopback.ipv4 or null);
              addr6 = requireString "${sitePath}.nodes.${nodeName}.loopback.ipv6" (loopback.ipv6 or null);
            };
            interfaces =
              buildTargetInterfaces {
                nodeName = nodeName;
                node = node;
                portLinks =
                  if targetDef == null then
                    { }
                  else
                    targetDef.linkLookup;
                targetId = targetId;
                realizedTarget = realizedTarget;
              };
          };
        }
        // (
          if nodeContainers != null then
            {
              availableContainers = nodeContainers;
            }
          else
            { }
        );
    };

  nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);

  runtimeTargetEntries =
    builtins.map
      (nodeName: buildRuntimeTarget nodeName nodes.${nodeName})
      (sortedNames nodes);
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
  domains = requireAttrs "${sitePath}.domains" (siteAttrs.domains or null);
  tenantPrefixOwners = tenantPrefixOwners;
  transit = buildCanonicalTransit;
  runtimeTargets = ensureUniqueEntries "${sitePath}.runtimeTargets" runtimeTargetEntries;
}
