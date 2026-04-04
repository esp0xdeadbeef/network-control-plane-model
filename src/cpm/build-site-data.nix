{ lib, helpers, realizationIndex }:

{ enterpriseName, siteName, site }:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    isNonEmptyString
    logicalKey
    sortedNames;

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

  validStringList = value:
    builtins.isList value && builtins.all isNonEmptyString value;

  stringOr = fallback: value:
    if isNonEmptyString value then
      value
    else
      fallback;

  stringListOr = fallback: value:
    if validStringList value then
      value
    else
      fallback;

  routesOrEmpty = value:
    if builtins.isAttrs value then
      {
        ipv4 =
          if builtins.isList (value.ipv4 or null) then
            value.ipv4
          else
            [ ];
        ipv6 =
          if builtins.isList (value.ipv6 or null) then
            value.ipv6
          else
            [ ];
      }
    else
      {
        ipv4 = [ ];
        ipv6 = [ ];
      };

  dedupeStringList = values:
    builtins.foldl'
      (acc: value:
        if builtins.elem value acc then
          acc
        else
          acc ++ [ value ])
      [ ]
      values;

  safeHead = fallback: values:
    if values == [ ] then
      fallback
    else
      builtins.elemAt values 0;

  sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
  siteAttrs = attrsOrEmpty site;
  nodes = attrsOrEmpty (siteAttrs.nodes or null);
  nodeNames = sortedNames nodes;

  roleNodeNames = role:
    builtins.filter
      (name: ((attrsOrEmpty nodes.${name}).role or null) == role)
      nodeNames;

  fallbackPolicyNodeName = safeHead "" (roleNodeNames "policy");
  fallbackUpstreamSelectorNodeName =
    let
      upstreamSelectors = roleNodeNames "upstream-selector";
    in
    if upstreamSelectors != [ ] then
      builtins.elemAt upstreamSelectors 0
    else
      fallbackPolicyNodeName;

  fallbackCoreNodeNames = roleNodeNames "core";

  domainsValue = attrsOrEmpty (siteAttrs.domains or null);
  domains =
    domainsValue
    // {
      tenants = listOrEmpty (domainsValue.tenants or null);
      externals = listOrEmpty (domainsValue.externals or null);
    };

  tenantPrefixOwners = attrsOrEmpty (siteAttrs.tenantPrefixOwners or null);

  buildSiteLinks =
    lib.mapAttrsSorted
      (linkName: linkValue:
        let
          link = attrsOrEmpty linkValue;
          fallbackId = "compat::${enterpriseName}.${siteName}::link::${linkName}";
        in
        link
        // {
          name = linkName;
          id = stringOr fallbackId (link.id or null);
          kind = stringOr "unknown" (link.kind or null);
        })
      (attrsOrEmpty (siteAttrs.links or null));

  siteLinks = buildSiteLinks;

  attachments = listOrEmpty (siteAttrs.attachments or null);

  attachmentLookup =
    let
      entries =
        builtins.genList
          (idx:
            let
              attachment = attrsOrEmpty (builtins.elemAt attachments idx);
              kind = stringOr "unknown" (attachment.kind or null);
              name = stringOr "attachment-${toString idx}" (attachment.name or null);
              unit = stringOr "unknown-unit" (attachment.unit or null);
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

  tenantAttachmentsForNode = nodeName:
    builtins.filter
      (attachment:
        (attachment.unit or null) == nodeName
        && (attachment.kind or null) == "tenant")
      (builtins.attrValues attachmentLookup);

  inferInterfaceKind = iface:
    if isNonEmptyString (iface.kind or null) then
      iface.kind
    else if isNonEmptyString (iface.tenant or null) then
      "tenant"
    else if isNonEmptyString (iface.overlay or null) then
      "overlay"
    else if isNonEmptyString (iface.upstream or null) then
      "wan"
    else if isNonEmptyString (iface.link or null) then
      if hasAttr (iface.link or "") siteLinks then
        stringOr "p2p" (siteLinks.${iface.link}.kind or null)
      else
        "p2p"
    else
      "unknown";

  inferredUplinkNames =
    dedupeStringList (
      builtins.concatLists (
        builtins.map
          (nodeName:
            let
              node = attrsOrEmpty nodes.${nodeName};
              interfaces = attrsOrEmpty (node.interfaces or null);
            in
            builtins.filter
              isNonEmptyString
              (
                builtins.map
                  (ifName:
                    let
                      iface = attrsOrEmpty interfaces.${ifName};
                    in
                    iface.upstream or null)
                  (sortedNames interfaces)
              ))
          nodeNames
      )
    );

  resolveBackingRef = nodeName: ifName: iface:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      sourceIfName = stringOr ifName (iface.interface or null);
      inferredKind = inferInterfaceKind iface;

      linkName =
        if isNonEmptyString (iface.link or null) then
          iface.link
        else
          null;

      tenantNameExplicit =
        if isNonEmptyString (iface.tenant or null) then
          iface.tenant
        else
          null;

      resolvedTenantName =
        if tenantNameExplicit != null then
          tenantNameExplicit
        else if hasAttr "${nodeName}|tenant|${sourceIfName}" attachmentLookup then
          sourceIfName
        else if hasAttr "${nodeName}|tenant|${ifName}" attachmentLookup then
          ifName
        else
          let
            candidates = tenantAttachmentsForNode nodeName;
          in
          if builtins.length candidates == 1 then
            (builtins.elemAt candidates 0).name
          else
            sourceIfName;

      overlayName =
        if isNonEmptyString (iface.overlay or null) then
          iface.overlay
        else
          sourceIfName;

      linkCandidate =
        if inferredKind == "tenant" || inferredKind == "overlay" || linkName == null then
          null
        else if hasAttr linkName siteLinks then
          let
            link = siteLinks.${linkName};
          in
          {
            kind = "link";
            id = link.id;
            name = linkName;
            linkKind = stringOr "unknown" (link.kind or null);
          }
        else
          {
            kind = "link";
            id = "compat::${enterpriseName}.${siteName}::link-ref::${linkName}";
            name = linkName;
            linkKind = "unknown";
          };

      attachmentCandidate =
        if inferredKind != "tenant" then
          null
        else
          let
            attachmentKey = "${nodeName}|tenant|${resolvedTenantName}";
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
            {
              kind = "attachment";
              id = "attachment::${nodeName}::tenant::${resolvedTenantName}";
              name = resolvedTenantName;
            };

      overlayCandidate =
        if inferredKind != "overlay" then
          null
        else
          {
            kind = "overlay";
            id = "overlay::${enterpriseName}.${siteName}::${overlayName}";
            name = overlayName;
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
    if builtins.length candidates == 1 then
      builtins.elemAt candidates 0
    else if linkName != null then
      {
        kind = "link";
        id = "compat::${enterpriseName}.${siteName}::link-ref::${linkName}";
        name = linkName;
        linkKind = "unknown";
      }
    else if inferredKind == "tenant" then
      {
        kind = "attachment";
        id = "attachment::${nodeName}::tenant::${resolvedTenantName}";
        name = resolvedTenantName;
      }
    else if inferredKind == "overlay" then
      {
        kind = "overlay";
        id = "overlay::${enterpriseName}.${siteName}::${overlayName}";
        name = overlayName;
      }
    else
      {
        kind = "attachment";
        id = "attachment::${nodeName}::unknown::${sourceIfName}";
        name = sourceIfName;
      };

  buildInterfaceEntry = { nodeName, ifName, iface, portLinks, targetId, realizedTarget }:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      ifaceAttrs = attrsOrEmpty iface;
      backingRef = resolveBackingRef nodeName ifName ifaceAttrs;
      sourceKind = inferInterfaceKind ifaceAttrs;
      sourceIfName = stringOr ifName (ifaceAttrs.interface or null);

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

      resolvedUpstream =
        if isNonEmptyString (ifaceAttrs.upstream or null) then
          ifaceAttrs.upstream
        else
          sourceIfName;

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
        (if sourceKind == "wan" then
          {
            upstream = resolvedUpstream;
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
          routes = routesOrEmpty (ifaceAttrs.routes or null);
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
      interfaces = attrsOrEmpty (node.interfaces or null);
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
      transitAttrs = attrsOrEmpty (siteAttrs.transit or null);
      adjacenciesRaw = listOrEmpty (transitAttrs.adjacencies or null);
      orderingRaw = transitAttrs.ordering or null;

      normalizeAdjacency = idx:
        let
          adjacency = attrsOrEmpty (builtins.elemAt adjacenciesRaw idx);
          linkName =
            if isNonEmptyString (adjacency.link or null) then
              adjacency.link
            else
              null;
          linkRef =
            if linkName != null && hasAttr linkName siteLinks then
              siteLinks.${linkName}
            else
              null;
          baseId =
            if isNonEmptyString (adjacency.id or null) then
              adjacency.id
            else if linkRef != null then
              linkRef.id
            else
              "compat::${enterpriseName}.${siteName}::adjacency::${toString idx}";
          baseKind =
            if isNonEmptyString (adjacency.kind or null) then
              adjacency.kind
            else if linkRef != null then
              stringOr "unknown" (linkRef.kind or null)
            else
              "unknown";
        in
        adjacency
        // {
          id = baseId;
          kind = baseKind;
          endpoints = listOrEmpty (adjacency.endpoints or null);
        }
        // (
          if linkName != null then
            {
              link = linkName;
              linkId =
                if linkRef != null then
                  linkRef.id
                else
                  "compat::${enterpriseName}.${siteName}::link-ref::${linkName}";
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

      rawAdjacencies =
        builtins.genList
          normalizeAdjacency
          (builtins.length adjacenciesRaw);

      normalizedAdjacencies =
        (
          builtins.foldl'
            (acc: adjacency:
              let
                baseId = adjacency.id;
                seenCount = acc.seen.${baseId} or 0;
                resolvedId =
                  if seenCount == 0 then
                    baseId
                  else
                    "${baseId}#compat-${toString seenCount}";
              in
              {
                seen =
                  acc.seen
                  // {
                    ${baseId} = seenCount + 1;
                  };
                ordered = acc.ordered ++ [ (adjacency // { id = resolvedId; }) ];
              })
            {
              seen = { };
              ordered = [ ];
            }
            rawAdjacencies
        ).ordered;

      adjacencyLookup =
        builtins.listToAttrs (
          builtins.map
            (adjacency: {
              name = adjacency.id;
              value = adjacency;
            })
            normalizedAdjacencies
        );

      adjacencyIds =
        builtins.map
          (adjacency: adjacency.id)
          normalizedAdjacencies;

      isPairOrderingEntry = entry:
        builtins.isList entry
        && builtins.length entry == 2
        && builtins.all isNonEmptyString entry;

      endpointsUnits = adjacency:
        builtins.map
          (endpoint:
            if builtins.isAttrs endpoint && isNonEmptyString (endpoint.unit or null) then
              endpoint.unit
            else
              null)
          (adjacency.endpoints or [ ]);

      mapPairToAdjacencyId = pair:
        let
          pairA = builtins.elemAt pair 0;
          pairB = builtins.elemAt pair 1;
          matches =
            builtins.filter
              (adjacency:
                let
                  units = endpointsUnits adjacency;
                in
                builtins.length units == 2
                && builtins.elemAt units 0 != null
                && builtins.elemAt units 1 != null
                && (
                  (
                    builtins.elemAt units 0 == pairA
                    && builtins.elemAt units 1 == pairB
                  )
                  || (
                    builtins.elemAt units 0 == pairB
                    && builtins.elemAt units 1 == pairA
                  )
                ))
              normalizedAdjacencies;
        in
        if matches == [ ] then
          null
        else
          (builtins.elemAt matches 0).id;

      candidateOrdering =
        if validStringList orderingRaw then
          orderingRaw
        else if builtins.isList orderingRaw && builtins.all isPairOrderingEntry orderingRaw then
          builtins.filter
            (value: value != null)
            (builtins.map mapPairToAdjacencyId orderingRaw)
        else
          [ ];

      filteredOrdering =
        dedupeStringList (
          builtins.filter
            (adjacencyId: builtins.elem adjacencyId adjacencyIds)
            candidateOrdering
        );

      ordering =
        filteredOrdering
        ++ builtins.filter
          (adjacencyId: !(builtins.elem adjacencyId filteredOrdering))
          adjacencyIds;
    in
    {
      ordering = ordering;
      adjacencies =
        builtins.map
          (adjacencyId: adjacencyLookup.${adjacencyId})
          ordering;
    };

  buildRuntimeTarget = nodeName: nodeValue:
    let
      node = attrsOrEmpty nodeValue;
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
            host = stringOr "" (targetDef.node.host or null);
            platform = stringOr "" (targetDef.node.platform or null);
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

      loopback = attrsOrEmpty (node.loopback or null);
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
              addr4 = stringOr "0.0.0.0/32" (loopback.ipv4 or null);
              addr6 = stringOr "::/128" (loopback.ipv6 or null);
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

  runtimeTargetEntries =
    builtins.map
      (nodeName: buildRuntimeTarget nodeName nodes.${nodeName})
      nodeNames;
in
{
  siteId = stringOr siteName (siteAttrs.siteId or null);
  siteName = stringOr "${enterpriseName}.${siteName}" (siteAttrs.siteName or null);
  attachments = attachments;
  policyNodeName = stringOr fallbackPolicyNodeName (siteAttrs.policyNodeName or null);
  upstreamSelectorNodeName =
    stringOr fallbackUpstreamSelectorNodeName (siteAttrs.upstreamSelectorNodeName or null);
  coreNodeNames = stringListOr fallbackCoreNodeNames (siteAttrs.coreNodeNames or null);
  uplinkCoreNames = stringListOr fallbackCoreNodeNames (siteAttrs.uplinkCoreNames or null);
  uplinkNames = stringListOr inferredUplinkNames (siteAttrs.uplinkNames or null);
  domains = domains;
  tenantPrefixOwners = tenantPrefixOwners;
  transit = buildCanonicalTransit;
  runtimeTargets = ensureUniqueEntries "${sitePath}.runtimeTargets" runtimeTargetEntries;
}
