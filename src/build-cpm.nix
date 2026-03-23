{ lib }:

{ forwardingModel, inventory ? {} }:

let
  hasAttr = name: attrs:
    builtins.isAttrs attrs && builtins.hasAttr name attrs;

  isNonEmptyString = value:
    builtins.isString value && value != "";

  forceAll = values:
    builtins.deepSeq values true;

  sortedNames = attrs:
    if builtins.isAttrs attrs then
      lib.attrNamesSorted attrs
    else
      [ ];

  requireAttrs = path: value:
    if builtins.isAttrs value then
      value
    else
      throw "input contract failure: ${path} must be an attribute set";

  requireList = path: value:
    if builtins.isList value then
      value
    else
      throw "input contract failure: ${path} must be a list";

  requireString = path: value:
    if isNonEmptyString value then
      value
    else
      throw "input contract failure: ${path} is required";

  requireStringList = path: value:
    if builtins.isList value && builtins.all isNonEmptyString value then
      value
    else
      throw "input contract failure: ${path} must contain only non-empty strings";

  requireRoutes = path: value:
    let
      routes = requireAttrs "${path}.routes" value;
      ipv4 = routes.ipv4 or [ ];
      ipv6 = routes.ipv6 or [ ];
    in
    if !builtins.isList ipv4 then
      throw "runtime realization failure: ${path}.routes.ipv4 must be a list"
    else if !builtins.isList ipv6 then
      throw "runtime realization failure: ${path}.routes.ipv6 must be a list"
    else
      {
        inherit ipv4 ipv6;
      };

  optionalAttrs = value:
    if value == null then
      { }
    else if builtins.isAttrs value then
      value
    else
      throw "input contract failure: expected attribute set, got ${builtins.typeOf value}";

  firstOr = fallback: values:
    if values == [ ] then
      fallback
    else
      builtins.elemAt values 0;

  attrCount = attrs:
    builtins.length (builtins.attrNames attrs);

  ensureUniqueEntries = path: entries:
    let
      attrs = builtins.listToAttrs entries;
    in
    if attrCount attrs != builtins.length entries then
      throw "input contract failure: ${path} contains duplicate identities"
    else
      attrs;

  logicalKey = logical:
    "${logical.enterprise}|${logical.site}|${logical.name}";

  validateTransit = sitePath: siteLinks: transit:
    let
      transitPath = "${sitePath}.transit";
      transitAttrs = requireAttrs transitPath transit;
      adjacencies = requireList "${transitPath}.adjacencies" (transitAttrs.adjacencies or null);
      orderingRaw = transitAttrs.ordering or null;

      ordering =
        if !builtins.isList orderingRaw then
          throw "transit.ordering must contain only stable adjacency IDs"
        else if !builtins.all isNonEmptyString orderingRaw then
          throw "transit.ordering must contain only stable adjacency IDs"
        else
          orderingRaw;

      adjacencyIds =
        builtins.genList
          (idx:
            let
              adjacencyPath = "${transitPath}.adjacencies[${toString idx}]";
              adjacency = requireAttrs adjacencyPath (builtins.elemAt adjacencies idx);
              adjacencyId = requireString "${adjacencyPath}.id" (adjacency.id or null);
              adjacencyKind = requireString "${adjacencyPath}.kind" (adjacency.kind or null);
              endpoints = requireList "${adjacencyPath}.endpoints" (adjacency.endpoints or null);

              _endpointCheck =
                if builtins.length endpoints > 0 then
                  true
                else
                  throw "input contract failure: ${adjacencyPath}.endpoints must not be empty";

              _linkCheck =
                if adjacencyKind == "p2p" then
                  let
                    linkName = requireString "${adjacencyPath}.link" (adjacency.link or null);
                  in
                  if !hasAttr linkName siteLinks then
                    throw "input contract failure: ${adjacencyPath}.link references unknown link '${linkName}'"
                  else
                    let
                      linkId = requireString "${sitePath}.links.${linkName}.id" (siteLinks.${linkName}.id or null);
                    in
                    if linkId != adjacencyId then
                      throw "input contract failure: ${adjacencyPath}.id '${adjacencyId}' does not match links.${linkName}.id '${linkId}'"
                    else
                      true
                else
                  true;
            in
            builtins.seq _endpointCheck (builtins.seq _linkCheck adjacencyId))
          (builtins.length adjacencies);

      _orderingMembership =
        builtins.map
          (adjacencyId:
            if builtins.elem adjacencyId adjacencyIds then
              true
            else
              throw "input contract failure: ${transitPath}.ordering references unknown adjacency ID '${adjacencyId}'")
          ordering;
    in
    builtins.seq (forceAll adjacencyIds) (forceAll _orderingMembership);

  validateNode = sitePath: nodeName: node:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath node;
      loopback = nodeAttrs.loopback or null;
      interfaces = nodeAttrs.interfaces or null;
    in
    if !builtins.isAttrs interfaces then
      throw "input contract failure: ${nodePath}.interfaces must be an attribute set"
    else if !builtins.isAttrs loopback then
      throw "node loopback is required"
    else if !isNonEmptyString (loopback.ipv4 or null) || !isNonEmptyString (loopback.ipv6 or null) then
      throw "node loopback is required"
    else
      true;

  validateSite = enterpriseName: siteName: site:
    let
      sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
      siteAttrs = requireAttrs sitePath site;

      _legacyAttachment =
        if siteAttrs ? attachment then
          throw "legacy singular attachment is not supported; use attachments"
        else
          true;

      _siteId = requireString "${sitePath}.siteId" (siteAttrs.siteId or null);
      _siteName = requireString "${sitePath}.siteName" (siteAttrs.siteName or null);
      _attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);
      _policyNodeName = requireString "${sitePath}.policyNodeName" (siteAttrs.policyNodeName or null);
      _upstreamSelectorNodeName =
        requireString "${sitePath}.upstreamSelectorNodeName" (siteAttrs.upstreamSelectorNodeName or null);
      _coreNodeNames = requireStringList "${sitePath}.coreNodeNames" (siteAttrs.coreNodeNames or null);
      _uplinkCoreNames = requireStringList "${sitePath}.uplinkCoreNames" (siteAttrs.uplinkCoreNames or null);
      _uplinkNames = requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);

      domains = requireAttrs "${sitePath}.domains" (siteAttrs.domains or null);
      _tenants = requireList "${sitePath}.domains.tenants" (domains.tenants or null);
      _externals = requireList "${sitePath}.domains.externals" (domains.externals or null);

      _tenantPrefixOwners =
        requireAttrs "${sitePath}.tenantPrefixOwners" (siteAttrs.tenantPrefixOwners or null);

      siteLinks = requireAttrs "${sitePath}.links" (siteAttrs.links or null);
      nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);

      _validatedNodes =
        builtins.map
          (nodeName': validateNode sitePath nodeName' nodes.${nodeName'})
          (sortedNames nodes);

      _validatedTransit = validateTransit sitePath siteLinks (siteAttrs.transit or null);
    in
    builtins.seq
      _legacyAttachment
      (builtins.seq
        _siteId
        (builtins.seq
          _siteName
          (builtins.seq
            _attachments
            (builtins.seq
              _policyNodeName
              (builtins.seq
                _upstreamSelectorNodeName
                (builtins.seq
                  _coreNodeNames
                  (builtins.seq
                    _uplinkCoreNames
                    (builtins.seq
                      _uplinkNames
                      (builtins.seq
                        _tenants
                        (builtins.seq
                          _externals
                          (builtins.seq
                            _tenantPrefixOwners
                            (builtins.seq (forceAll _validatedNodes) _validatedTransit))))))))))));

  validateForwardingModel = input:
    let
      inputAttrs =
        if builtins.isAttrs input then
          input
        else
          throw "forwarding model input must be an attribute set";

      meta = inputAttrs.meta or null;

      marker =
        if builtins.isAttrs meta && builtins.isAttrs ((meta).networkForwardingModel or null) then
          meta.networkForwardingModel
        else
          throw "forwarding model input requires meta.networkForwardingModel";

      schemaVersion = marker.schemaVersion or null;
      enterprise = requireAttrs "forwardingModel.enterprise" (inputAttrs.enterprise or null);
    in
    if schemaVersion != 6 then
      throw "unsupported forwarding model schema version '${toString schemaVersion}' (expected 6)"
    else
      forceAll (
        builtins.map
          (enterpriseName:
            let
              enterpriseValue =
                requireAttrs
                  "forwardingModel.enterprise.${enterpriseName}"
                  enterprise.${enterpriseName};
              sites =
                requireAttrs
                  "forwardingModel.enterprise.${enterpriseName}.site"
                  (enterpriseValue.site or null);
            in
            forceAll (
              builtins.map
                (siteName: validateSite enterpriseName siteName sites.${siteName})
                (sortedNames sites)
            ))
          (sortedNames enterprise)
      );

  buildPortLinkLookup = nodePath: ports:
    let
      portNames = sortedNames ports;
      entries =
        builtins.map
          (portName:
            let
              portPath = "${nodePath}.ports.${portName}";
              port = requireAttrs portPath ports.${portName};
              interface = requireAttrs "${portPath}.interface" (port.interface or null);
              linkRef = requireString "${portPath}.link" (port.link or null);
              runtimeIfName = requireString "${portPath}.interface.name" (interface.name or null);
            in
            {
              name = linkRef;
              value = {
                runtimePort = portName;
                runtimeIfName = runtimeIfName;
                attach = port.attach or null;
              };
            })
          portNames;
    in
    ensureUniqueEntries "${nodePath}.ports[*].link" entries;

  realizationIndex =
    let
      inventoryRoot = optionalAttrs inventory;
      realizationRoot = optionalAttrs (inventoryRoot.realization or null);
      realizationNodes = optionalAttrs (realizationRoot.nodes or null);
    in
    builtins.foldl'
      (acc: targetName:
        let
          nodePath = "inventory.realization.nodes.${targetName}";
          node = requireAttrs nodePath realizationNodes.${targetName};
          logicalNode = requireAttrs "${nodePath}.logicalNode" (node.logicalNode or null);
          logical = {
            enterprise =
              requireString "${nodePath}.logicalNode.enterprise" (logicalNode.enterprise or null);
            site =
              requireString "${nodePath}.logicalNode.site" (logicalNode.site or null);
            name =
              requireString "${nodePath}.logicalNode.name" (logicalNode.name or null);
          };
          key = logicalKey logical;
          ports = optionalAttrs (node.ports or null);
          linkLookup = buildPortLinkLookup nodePath ports;
        in
        if hasAttr key acc.byLogical then
          throw "runtime realization failure: logical node '${key}' is realized by multiple runtime targets"
        else
          {
            byLogical =
              acc.byLogical
              // {
                ${key} = targetName;
              };

            targetDefs =
              acc.targetDefs
              // {
                ${targetName} = {
                  targetName = targetName;
                  nodePath = nodePath;
                  node = node;
                  logical = logical;
                  linkLookup = linkLookup;
                };
              };
          })
      {
        byLogical = { };
        targetDefs = { };
      }
      (sortedNames (optionalAttrs ((optionalAttrs ((optionalAttrs inventory).realization or null)).nodes or null)));

  buildSiteLinks = sitePath: siteAttrs:
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

  buildAttachmentLookup = sitePath: attachments:
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

  resolveBackingRef = sitePath: nodeName: ifName: siteLinks: attachmentLookup: iface:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      kind = requireString "${ifacePath}.kind" (iface.kind or null);
      linkName =
        if isNonEmptyString (iface.link or null) then
          iface.link
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
    else
      throw ''
        runtime realization failure: ${ifacePath} must resolve to exactly one backing reference
          kind = ${toString (iface.kind or null)}
          link = ${toString (iface.link or null)}
      '';

  buildInterfaceEntry =
    {
      sitePath,
      nodeName,
      ifName,
      iface,
      siteLinks,
      attachmentLookup,
      portLinks,
      targetId,
    }:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      ifaceAttrs = requireAttrs ifacePath iface;
      backingRef = resolveBackingRef sitePath nodeName ifName siteLinks attachmentLookup ifaceAttrs;

      sourceIfName =
        if isNonEmptyString (ifaceAttrs.interface or null) then
          ifaceAttrs.interface
        else
          ifName;

      runtimeIfName =
        if (backingRef.kind or null) == "link" && hasAttr backingRef.id portLinks then
          portLinks.${backingRef.id}.runtimeIfName
        else if (backingRef.kind or null) == "link" && hasAttr backingRef.name portLinks then
          portLinks.${backingRef.name}.runtimeIfName
        else
          sourceIfName;
    in
    {
      name = ifName;
      value = {
        runtimeTarget = targetId;
        logicalNode = nodeName;
        sourceInterface = ifName;
        sourceKind = requireString "${ifacePath}.kind" (ifaceAttrs.kind or null);
        runtimeIfName = runtimeIfName;
        renderedIfName = runtimeIfName;
        addr4 = ifaceAttrs.addr4 or null;
        addr6 = ifaceAttrs.addr6 or null;
        routes = requireRoutes ifacePath (ifaceAttrs.routes or null);
        backingRef = backingRef;
      };
    };

  buildTargetInterfaces =
    {
      sitePath,
      nodeName,
      node,
      siteLinks,
      attachmentLookup,
      portLinks,
      targetId,
    }:
    let
      interfaces = requireAttrs "${sitePath}.nodes.${nodeName}.interfaces" (node.interfaces or null);
      entries =
        builtins.map
          (ifName:
            buildInterfaceEntry {
              sitePath = sitePath;
              nodeName = nodeName;
              ifName = ifName;
              iface = interfaces.${ifName};
              siteLinks = siteLinks;
              attachmentLookup = attachmentLookup;
              portLinks = portLinks;
              targetId = targetId;
            })
          (sortedNames interfaces);
    in
    builtins.listToAttrs entries;

  buildCanonicalTransit = sitePath: siteLinks: transit:
    let
      transitPath = "${sitePath}.transit";
      transitAttrs = requireAttrs transitPath transit;
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

  buildRuntimeTarget =
    {
      enterpriseName,
      siteName,
      sitePath,
      nodeName,
      node,
      siteLinks,
      attachmentLookup,
    }:
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
              sitePath = sitePath;
              nodeName = nodeName;
              node = node;
              siteLinks = siteLinks;
              attachmentLookup = attachmentLookup;
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

  buildSiteData = enterpriseName: siteName: site:
    let
      sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
      siteAttrs = requireAttrs sitePath site;
      siteLinks = buildSiteLinks sitePath siteAttrs;
      attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);
      attachmentLookup = buildAttachmentLookup sitePath attachments;
      nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);

      runtimeTargetEntries =
        builtins.map
          (nodeName:
            buildRuntimeTarget {
              enterpriseName = enterpriseName;
              siteName = siteName;
              sitePath = sitePath;
              nodeName = nodeName;
              node = nodes.${nodeName};
              siteLinks = siteLinks;
              attachmentLookup = attachmentLookup;
            })
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
      tenantPrefixOwners =
        requireAttrs "${sitePath}.tenantPrefixOwners" (siteAttrs.tenantPrefixOwners or null);
      transit = buildCanonicalTransit sitePath siteLinks (siteAttrs.transit or null);
      runtimeTargets = ensureUniqueEntries "${sitePath}.runtimeTargets" runtimeTargetEntries;
    };

  _validated = validateForwardingModel forwardingModel;

  marker = forwardingModel.meta.networkForwardingModel;
  enterprise = requireAttrs "forwardingModel.enterprise" (forwardingModel.enterprise or null);

  cpmData =
    lib.mapAttrsSorted
      (enterpriseName: enterpriseValue:
        let
          sites =
            requireAttrs
              "forwardingModel.enterprise.${enterpriseName}.site"
              (enterpriseValue.site or null);
        in
        lib.mapAttrsSorted
          (siteName: site: buildSiteData enterpriseName siteName site)
          sites)
      enterprise;
in
builtins.seq _validated {
  version = 1;
  source = "nix";
  inputContract = {
    upstream = marker.name or "network-forwarding-model";
    schemaVersion = marker.schemaVersion or null;
  };
  data = cpmData;
}
