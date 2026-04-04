{ helpers }:

forwardingModel:

let
  inherit (helpers)
    ensureUniqueEntries
    failWithContext
    forceAll
    hasAttr
    isNonEmptyString
    renderValue
    requireAttrs
    requireAttrsIn
    requireList
    requireListIn
    requireString
    requireStringIn
    requireStringList
    requireStringListIn
    sortedNames;

  warnWithContext = message: context:
    builtins.trace
      "migration warning: ${message}\n--- offending input context ---\n${renderValue context}"
      true;

  makeStringSet = values:
    builtins.listToAttrs (
      builtins.map
        (value: {
          name = value;
          value = true;
        })
        values
    );

  validateContractTagMappings = sitePath: siteAttrs:
    let
      communicationContractValue = siteAttrs.communicationContract or null;
      communicationContract =
        if communicationContractValue == null then
          null
        else
          requireAttrsIn
            siteAttrs
            "${sitePath}.communicationContract"
            communicationContractValue;
    in
    if communicationContract == null then
      true
    else
      let
        allowedRelations =
          requireListIn
            communicationContract
            "${sitePath}.communicationContract.allowedRelations"
            (communicationContract.allowedRelations or null);

        policy =
          if builtins.isAttrs (siteAttrs.policy or null) then
            siteAttrs.policy
          else
            null;

        policyInterfaceTagsValue =
          if policy == null then
            null
          else
            policy.interfaceTags or null;

        contractInterfaceTagsValue =
          communicationContract.interfaceTags or null;

        hasPolicyInterfaceTags = builtins.isAttrs policyInterfaceTagsValue;
        hasContractInterfaceTags = builtins.isAttrs contractInterfaceTagsValue;

        interfaceTags =
          if hasPolicyInterfaceTags && hasContractInterfaceTags then
            failWithContext
              "exactly one canonical interfaceTags source is allowed; use communicationContract.interfaceTags"
              {
                policy = policyInterfaceTagsValue;
                communicationContract = contractInterfaceTagsValue;
              }
          else if hasPolicyInterfaceTags then
            failWithContext
              "policy.interfaceTags is not supported; use communicationContract.interfaceTags"
              policy
          else if !hasContractInterfaceTags then
            failWithContext
              "communicationContract.interfaceTags is required"
              communicationContract
          else
            requireAttrsIn
              communicationContract
              "${sitePath}.communicationContract.interfaceTags"
              contractInterfaceTagsValue;

        explicitTagSet =
          makeStringSet (
            builtins.filter
              isNonEmptyString
              (builtins.attrValues interfaceTags)
          );

        referencedTags =
          builtins.concatLists (
            builtins.genList
              (idx:
                let
                  relationPath =
                    "${sitePath}.communicationContract.allowedRelations[${toString idx}]";
                  relation =
                    requireAttrsIn
                      communicationContract
                      relationPath
                      (builtins.elemAt allowedRelations idx);

                  collectEndpointTags = endpointName:
                    let
                      endpointPath = "${relationPath}.${endpointName}";
                      endpointRaw = relation.${endpointName} or null;
                    in
                    if endpointRaw == "any" then
                      [ ]
                    else if builtins.isAttrs endpointRaw then
                      let
                        endpoint =
                          requireAttrsIn
                            relation
                            endpointPath
                            endpointRaw;
                        kind =
                          requireStringIn
                            endpoint
                            "${endpointPath}.kind"
                            (endpoint.kind or null);
                      in
                      if kind == "tenant" || kind == "service" then
                        [
                          (
                            requireStringIn
                              endpoint
                              "${endpointPath}.name"
                              (endpoint.name or null)
                          )
                        ]
                      else if kind == "external" then
                        let
                          externalName =
                            if isNonEmptyString (endpoint.name or null) then
                              endpoint.name
                            else
                              null;

                          externalUplinks =
                            if endpoint.uplinks or null == null then
                              null
                            else
                              requireStringListIn
                                endpoint
                                "${endpointPath}.uplinks"
                                (endpoint.uplinks or null);
                        in
                        if externalName != null then
                          [ externalName ]
                        else if externalUplinks != null then
                          externalUplinks
                        else
                          failWithContext
                            "input contract failure: ${endpointPath} external endpoint requires name or uplinks"
                            endpoint
                      else if kind == "tenant-set" then
                        requireStringListIn
                          endpoint
                          "${endpointPath}.members"
                          (endpoint.members or null)
                      else
                        [ ]
                    else
                      failWithContext
                        "input contract failure: ${endpointPath} must be an attribute set or the string \"any\""
                        relation;
                in
                collectEndpointTags "from" ++ collectEndpointTags "to")
              (builtins.length allowedRelations)
          );

        validatedTags =
          builtins.genList
            (idx:
              let
                tag = builtins.elemAt referencedTags idx;
              in
              if hasAttr tag explicitTagSet then
                true
              else
                failWithContext
                  "communicationContract references tag '${tag}' with no explicit interfaceTags mapping"
                  {
                    interfaceTags = interfaceTags;
                    referencedTag = tag;
                    site = sitePath;
                  })
            (builtins.length referencedTags);
      in
      forceAll validatedTags;

  validateBGP = sitePath: siteAttrs:
    let
      bgpValue = siteAttrs.bgp or null;
      bgp =
        if bgpValue == null then
          null
        else
          requireAttrsIn siteAttrs "${sitePath}.bgp" bgpValue;
      mode =
        if bgp == null then
          null
        else
          bgp.mode or null;
      sessions =
        if bgp == null then
          null
        else
          bgp.sessions or null;
    in
    if mode == "bgp" && !builtins.isList sessions then
      failWithContext "bgp mode requires explicit site.bgp.sessions" bgp
    else
      true;

  validateTransit = sitePath: siteLinks: siteAttrs: transit:
    let
      transitPath = "${sitePath}.transit";
      transitAttrs = requireAttrsIn siteAttrs transitPath transit;
      adjacencies =
        requireListIn
          transitAttrs
          "${transitPath}.adjacencies"
          (transitAttrs.adjacencies or null);
      orderingRaw = transitAttrs.ordering or null;

      ordering =
        if !builtins.isList orderingRaw then
          failWithContext
            "transit.ordering must contain only stable adjacency IDs"
            transitAttrs
        else if !builtins.all isNonEmptyString orderingRaw then
          failWithContext
            "transit.ordering must contain only stable adjacency IDs"
            transitAttrs
        else
          orderingRaw;

      adjacencyIds =
        builtins.genList
          (idx:
            let
              adjacencyPath = "${transitPath}.adjacencies[${toString idx}]";
              adjacency =
                requireAttrsIn
                  transitAttrs
                  adjacencyPath
                  (builtins.elemAt adjacencies idx);
              adjacencyId =
                requireStringIn
                  adjacency
                  "${adjacencyPath}.id"
                  (adjacency.id or null);
              adjacencyKind =
                requireStringIn
                  adjacency
                  "${adjacencyPath}.kind"
                  (adjacency.kind or null);
              endpoints =
                requireListIn
                  adjacency
                  "${adjacencyPath}.endpoints"
                  (adjacency.endpoints or null);

              endpointCheck =
                if builtins.length endpoints > 0 then
                  true
                else
                  failWithContext
                    "input contract failure: ${adjacencyPath}.endpoints must not be empty"
                    adjacency;

              linkCheck =
                if adjacencyKind == "p2p" then
                  let
                    linkName =
                      requireStringIn
                        adjacency
                        "${adjacencyPath}.link"
                        (adjacency.link or null);
                  in
                  if !hasAttr linkName siteLinks then
                    failWithContext
                      "input contract failure: ${adjacencyPath}.link references unknown link '${linkName}'"
                      {
                        adjacency = adjacency;
                        availableLinks = builtins.attrNames siteLinks;
                      }
                  else
                    let
                      linkId =
                        requireStringIn
                          siteLinks.${linkName}
                          "${sitePath}.links.${linkName}.id"
                          (siteLinks.${linkName}.id or null);
                    in
                    if linkId != adjacencyId then
                      failWithContext
                        "input contract failure: ${adjacencyPath}.id '${adjacencyId}' does not match links.${linkName}.id '${linkId}'"
                        {
                          adjacency = adjacency;
                          link = siteLinks.${linkName};
                        }
                    else
                      true
                else
                  true;
            in
            builtins.seq endpointCheck (builtins.seq linkCheck adjacencyId))
          (builtins.length adjacencies);

      orderingMembership =
        builtins.map
          (adjacencyId:
            if builtins.elem adjacencyId adjacencyIds then
              true
            else
              failWithContext
                "input contract failure: ${transitPath}.ordering references unknown adjacency ID '${adjacencyId}'"
                {
                  ordering = ordering;
                  knownAdjacencyIds = adjacencyIds;
                })
          ordering;
    in
    builtins.seq (forceAll adjacencyIds) (forceAll orderingMembership);

  validateInterface = sitePath: attachmentLookup: siteLinks: nodeName: ifName: nodeAttrs: iface:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      ifaceAttrs = requireAttrsIn nodeAttrs ifacePath iface;
      kind = ifaceAttrs.kind or null;
      interfaceValue = ifaceAttrs.interface or null;
      linkValue = ifaceAttrs.link or null;

      legacyTenantLinkWarning =
        if kind == "tenant" && isNonEmptyString linkValue then
          warnWithContext
            "tenant interface declares legacy link field; keeping attachment-backed behavior"
            {
              site = sitePath;
              node = nodeName;
              interfaceKey = ifName;
              interfaceDefinition = ifaceAttrs;
            }
        else
          true;

      legacyOverlayLinkWarning =
        if kind == "overlay" && isNonEmptyString linkValue then
          warnWithContext
            "overlay interface declares legacy link field; keeping overlay-backed behavior"
            {
              site = sitePath;
              node = nodeName;
              interfaceKey = ifName;
              interfaceDefinition = ifaceAttrs;
            }
        else
          true;

      tenantAttachmentCheck =
        if kind == "tenant" then
          let
            tenantName =
              requireStringIn
                ifaceAttrs
                "${ifacePath}.tenant"
                (ifaceAttrs.tenant or null);
            attachmentKey = "${nodeName}|tenant|${tenantName}";
          in
          if hasAttr attachmentKey attachmentLookup then
            true
          else
            failWithContext
              "tenant interface requires explicit site.attachments entry"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                tenant = tenantName;
                interfaceDefinition = ifaceAttrs;
              }
        else
          true;

      matchingLinkCheck =
        if isNonEmptyString linkValue && kind != "tenant" && kind != "overlay" then
          if hasAttr linkValue siteLinks then
            true
          else
            failWithContext
              "realized link interface requires explicit matching link"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                link = linkValue;
                knownLinks = sortedNames siteLinks;
                interfaceDefinition = ifaceAttrs;
              }
        else
          true;
    in
    if !isNonEmptyString kind then
      failWithContext
        "interface kind is required"
        {
          site = sitePath;
          node = nodeName;
          interfaceKey = ifName;
          interfaceDefinition = ifaceAttrs;
        }
    else if !isNonEmptyString interfaceValue then
      failWithContext
        "input contract failure: ${ifacePath}.interface is required"
        {
          site = sitePath;
          node = nodeName;
          interfaceKey = ifName;
          availableInterfaceKeys =
            if builtins.isAttrs (nodeAttrs.interfaces or null) then
              sortedNames nodeAttrs.interfaces
            else
              [ ];
          interfaceFields =
            if builtins.isAttrs ifaceAttrs then
              sortedNames ifaceAttrs
            else
              [ ];
          interfaceDefinition = ifaceAttrs;
          nodeDefinition = nodeAttrs;
        }
    else
      builtins.seq
        legacyTenantLinkWarning
        (builtins.seq
          legacyOverlayLinkWarning
          (if kind == "tenant" && !isNonEmptyString (ifaceAttrs.tenant or null) then
            failWithContext
              "tenant interface requires explicit tenant"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = ifaceAttrs;
              }
          else if kind == "wan" && !isNonEmptyString (ifaceAttrs.upstream or null) then
            failWithContext
              "wan interface requires explicit upstream"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = ifaceAttrs;
              }
          else if kind == "wan" && !isNonEmptyString linkValue then
            failWithContext
              "wan interface requires explicit link"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = ifaceAttrs;
              }
          else if kind == "overlay" && !isNonEmptyString (ifaceAttrs.overlay or null) then
            failWithContext
              "overlay interface requires explicit overlay"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = ifaceAttrs;
              }
          else
            builtins.seq tenantAttachmentCheck matchingLinkCheck));

  validateNode = sitePath: attachmentLookup: siteLinks: nodeName: node:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrsIn nodePath nodePath node;
      loopback = nodeAttrs.loopback or null;
      interfaces = nodeAttrs.interfaces or null;
      interfaceNames =
        if builtins.isAttrs interfaces then
          sortedNames interfaces
        else
          [ ];

      validatedInterfaces =
        if builtins.isAttrs interfaces then
          builtins.map
            (ifName:
              validateInterface
                sitePath
                attachmentLookup
                siteLinks
                nodeName
                ifName
                nodeAttrs
                interfaces.${ifName})
            interfaceNames
        else
          [ ];

      hasExplicitTenantInterface =
        builtins.any
          (ifName:
            let
              iface = interfaces.${ifName};
            in
            builtins.isAttrs iface
            && (iface.kind or null) == "tenant"
            && isNonEmptyString (iface.tenant or null))
          interfaceNames;
    in
    if !builtins.isAttrs interfaces then
      failWithContext
        "input contract failure: ${nodePath}.interfaces must be an attribute set"
        nodeAttrs
    else if !builtins.isAttrs loopback then
      failWithContext "node loopback is required" nodeAttrs
    else if !isNonEmptyString (loopback.ipv4 or null) || !isNonEmptyString (loopback.ipv6 or null) then
      failWithContext "node loopback is required" loopback
    else
      builtins.seq
        (forceAll validatedInterfaces)
        (if (nodeAttrs.role or null) == "access" && !hasExplicitTenantInterface then
          failWithContext
            "access node requires at least one tenant interface with explicit tenant"
            nodeAttrs
        else
          true);

  validateSite = enterpriseName: siteName: site:
    let
      sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
      siteAttrs = requireAttrs sitePath site;

      legacyAttachment =
        if siteAttrs ? attachment then
          failWithContext
            "legacy singular attachment is not supported; use attachments"
            siteAttrs
        else
          true;

      siteId = requireStringIn siteAttrs "${sitePath}.siteId" (siteAttrs.siteId or null);
      siteNameValue =
        requireStringIn siteAttrs "${sitePath}.siteName" (siteAttrs.siteName or null);
      attachments =
        requireListIn siteAttrs "${sitePath}.attachments" (siteAttrs.attachments or null);

      attachmentLookup =
        ensureUniqueEntries
          "${sitePath}.attachments"
          (
            builtins.genList
              (idx:
                let
                  attachmentPath = "${sitePath}.attachments[${toString idx}]";
                  attachment =
                    requireAttrsIn
                      siteAttrs
                      attachmentPath
                      (builtins.elemAt attachments idx);
                  kind =
                    requireStringIn
                      attachment
                      "${attachmentPath}.kind"
                      (attachment.kind or null);
                  name =
                    requireStringIn
                      attachment
                      "${attachmentPath}.name"
                      (attachment.name or null);
                  unit =
                    requireStringIn
                      attachment
                      "${attachmentPath}.unit"
                      (attachment.unit or null);
                in
                {
                  name = "${unit}|${kind}|${name}";
                  value = attachment;
                })
              (builtins.length attachments)
          );

      policyNodeName =
        requireStringIn
          siteAttrs
          "${sitePath}.policyNodeName"
          (siteAttrs.policyNodeName or null);
      upstreamSelectorNodeName =
        requireStringIn
          siteAttrs
          "${sitePath}.upstreamSelectorNodeName"
          (siteAttrs.upstreamSelectorNodeName or null);
      coreNodeNames =
        requireStringListIn
          siteAttrs
          "${sitePath}.coreNodeNames"
          (siteAttrs.coreNodeNames or null);
      uplinkCoreNames =
        requireStringListIn
          siteAttrs
          "${sitePath}.uplinkCoreNames"
          (siteAttrs.uplinkCoreNames or null);
      uplinkNames =
        requireStringListIn
          siteAttrs
          "${sitePath}.uplinkNames"
          (siteAttrs.uplinkNames or null);

      domains = requireAttrsIn siteAttrs "${sitePath}.domains" (siteAttrs.domains or null);
      tenants =
        requireListIn
          domains
          "${sitePath}.domains.tenants"
          (domains.tenants or null);
      externals =
        requireListIn
          domains
          "${sitePath}.domains.externals"
          (domains.externals or null);
      tenantPrefixOwners =
        requireAttrsIn
          siteAttrs
          "${sitePath}.tenantPrefixOwners"
          (siteAttrs.tenantPrefixOwners or null);

      siteLinks =
        requireAttrsIn siteAttrs "${sitePath}.links" (siteAttrs.links or null);
      nodes =
        requireAttrsIn siteAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);

      validatedNodes =
        builtins.map
          (nodeName:
            validateNode
              sitePath
              attachmentLookup
              siteLinks
              nodeName
              nodes.${nodeName})
          (sortedNames nodes);

      validatedTransit =
        validateTransit sitePath siteLinks siteAttrs (siteAttrs.transit or null);
      validatedContractTags = validateContractTagMappings sitePath siteAttrs;
      validatedBGP = validateBGP sitePath siteAttrs;
    in
    forceAll [
      legacyAttachment
      siteId
      siteNameValue
      attachments
      policyNodeName
      upstreamSelectorNodeName
      coreNodeNames
      uplinkCoreNames
      uplinkNames
      tenants
      externals
      tenantPrefixOwners
      validatedNodes
      validatedTransit
      validatedContractTags
      validatedBGP
    ];

  inputAttrs =
    if builtins.isAttrs forwardingModel then
      forwardingModel
    else
      throw "forwarding model input must be an attribute set";

  meta = forwardingModel.meta or null;

  marker =
    if builtins.isAttrs meta && builtins.isAttrs (meta.networkForwardingModel or null) then
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
  )
