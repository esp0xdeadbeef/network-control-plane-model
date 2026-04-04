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
            throw "tenant interface requires explicit site.attachments entry";
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
            throw "input contract failure: ${ifacePath}.link references unknown site link '${linkName}'";
      in
      {
        kind = "link";
        id = link.id;
        name = linkName;
        linkKind = link.kind;
      };

  buildInterfaceEntry = { nodeName, ifName, iface, portLinks, targetId, realizedTarget }:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      ifaceAttrs = requireAttrs ifacePath iface;
      sourceKind = requireString "${ifacePath}.kind" (ifaceAttrs.kind or null);
      sourceIfName = requireString "${ifacePath}.interface" (ifaceAttrs.interface or null);
      backingRef = resolveBackingRef nodeName ifName ifaceAttrs;

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
          backingRef = builtins.removeAttrs backingRef [ "linkKind" ];
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
            { }
        );
    in
    {
      name = ifName;
      value = baseValue;
    };

  buildTargetInterfaces = { nodeName, node, portLinks, targetId, realizedTarget }:
    let
      interfaces = requireAttrs "${sitePath}.nodes.${nodeName}.interfaces" (node.interfaces or null);
    in
    builtins.listToAttrs (
      builtins.map
        (ifName:
          buildInterfaceEntry {
            inherit nodeName ifName portLinks targetId realizedTarget;
            iface = interfaces.${ifName};
          })
        (sortedNames interfaces)
    );

  buildCanonicalTransit =
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
              throw "input contract failure: ${sitePath}.transit.ordering references unknown adjacency id '${adjacencyId}'")
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
                inherit nodeName node targetId realizedTarget;
                portLinks =
                  if targetDef == null then
                    { }
                  else
                    targetDef.linkLookup;
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
  domains = domains;
  tenantPrefixOwners = tenantPrefixOwners;
  transit = buildCanonicalTransit;
  runtimeTargets = ensureUniqueEntries "${sitePath}.runtimeTargets" runtimeTargetEntries;
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
  if builtins.isAttrs (siteAttrs.forwardingSemantics or null) then
    {
      forwardingSemantics = siteAttrs.forwardingSemantics;
    }
  else
    { }
)
