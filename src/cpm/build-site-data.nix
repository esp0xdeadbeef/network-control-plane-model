{ lib, helpers, realizationIndex }:

{ enterpriseName, siteName, site }:

let
  inherit (helpers)
    ensureUniqueEntries
    firstOr
    hasAttr
    isNonEmptyString
    logicalKey
    requireAttrs
    requireList
    requireRoutes
    requireString
    requireStringList
    sortedNames;

  sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
  siteAttrs = requireAttrs sitePath site;

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
      overlayName =
        if isNonEmptyString (iface.overlay or null) then
          iface.overlay
        else if linkName != null then
          linkName
        else
          null;
    in
    if linkName != null && hasAttr linkName siteLinks then
      let
        link = siteLinks.${linkName};
      in
      {
        kind = "link";
        id = requireString "${sitePath}.links.${linkName}.id" (link.id or null);
        name = linkName;
      }
    else if kind == "tenant" then
      let
        tenant = requireString "${ifacePath}.tenant" (iface.tenant or null);
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
        throw "runtime realization failure: ${ifacePath} could not resolve tenant attachment '${tenant}'"
    else if kind == "overlay" then
      let
        resolvedOverlayName =
          requireString "${ifacePath}.overlay" overlayName;
      in
      {
        kind = "overlay";
        id = "overlay::${enterpriseName}.${siteName}::${resolvedOverlayName}";
        name = resolvedOverlayName;
      }
    else
      throw ''
        runtime realization failure: ${ifacePath} must resolve to exactly one backing reference
          kind = ${toString (iface.kind or null)}
          link = ${toString (iface.link or null)}
      '';

  buildInterfaceEntry = { nodeName, ifName, iface, portLinks, targetId }:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      ifaceAttrs = requireAttrs ifacePath iface;
      backingRef = resolveBackingRef nodeName ifName ifaceAttrs;

      sourceIfName =
        if isNonEmptyString (ifaceAttrs.interface or null) then
          ifaceAttrs.interface
        else
          ifName;

      sourceKind = requireString "${ifacePath}.kind" (ifaceAttrs.kind or null);

      portLink =
        if (backingRef.kind or null) == "link" && hasAttr backingRef.id portLinks then
          portLinks.${backingRef.id}
        else if (backingRef.kind or null) == "link" && hasAttr backingRef.name portLinks then
          portLinks.${backingRef.name}
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
          backingRef = backingRef;
        }
        // wanModelExtras
        // wanInventoryExtras;
    };

  buildTargetInterfaces = { nodeName, node, portLinks, targetId }:
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
                  displayName =
                    if isNonEmptyString (adjacency.name or null) then
                      adjacency.name
                    else if linkName != null then
                      linkName
                    else
                      adjacencyId;
                  linkId =
                    if linkName != null && hasAttr linkName siteLinks then
                      siteLinks.${linkName}.id
                    else
                      adjacencyId;
                in
                {
                  name = adjacencyId;
                  value = {
                    id = adjacencyId;
                    kind = requireString "${adjacencyPath}.kind" (adjacency.kind or null);
                    link = linkName;
                    name = displayName;
                    linkId = linkId;
                    routingParticipation = adjacency.routingParticipation or false;
                    endpoints = requireList "${adjacencyPath}.endpoints" (adjacency.endpoints or null);
                  };
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

      availableContainers =
        if builtins.isList (node.containers or null) then
          node.containers
        else
          [ "default" ];

      placement =
        if targetDef == null then
          {
            kind = "logical-node";
            runtimeTargetId = targetId;
            host = null;
            platform = null;
            container = firstOr "default" availableContainers;
            isolation = "default";
          }
        else
          {
            kind = "inventory-realization";
            runtimeTargetId = targetId;
            host = requireString "${targetDef.nodePath}.host" (targetDef.node.host or null);
            platform = requireString "${targetDef.nodePath}.platform" (targetDef.node.platform or null);
            container =
              if isNonEmptyString (targetDef.node.container or null) then
                targetDef.node.container
              else
                firstOr "default" availableContainers;
            isolation =
              if isNonEmptyString (targetDef.node.isolation or null) then
                targetDef.node.isolation
              else
                "default";
          };

      loopback = requireAttrs "${sitePath}.nodes.${nodeName}.loopback" (node.loopback or null);
    in
    {
      name = targetId;
      value = {
        runtimeTargetId = targetId;
        role = node.role or null;
        logicalNode = logical;
        placement = placement;
        availableContainers = availableContainers;
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
            };
        };
      };
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
  tenantPrefixOwners = requireAttrs "${sitePath}.tenantPrefixOwners" (siteAttrs.tenantPrefixOwners or null);
  transit = buildCanonicalTransit;
  runtimeTargets = ensureUniqueEntries "${sitePath}.runtimeTargets" runtimeTargetEntries;
}
