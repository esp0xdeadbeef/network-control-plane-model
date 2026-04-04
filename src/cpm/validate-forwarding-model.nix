{
  helpers
}:

forwardingModel:

let
  inherit (helpers)
    forceAll
    hasAttr
    isNonEmptyString
    requireAttrs
    requireList
    sortedNames
    ;

  baseValidator =
    (import ../../invariants/default.nix {
      lib = {
        attrNamesSorted = sortedNames;
      };
    }).validateForwardingModelInput;

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

  makeStringSet = values:
    builtins.listToAttrs (
      builtins.map
        (value: {
          name = value;
          value = true;
        })
        values
    );

  attachmentLookupForSite = attachments:
    makeStringSet (
      builtins.filter
        isNonEmptyString
        (
          builtins.map
            (attachment:
              let
                attachmentAttrs = attrsOrEmpty attachment;
                kind = attachmentAttrs.kind or null;
                name = attachmentAttrs.name or null;
                unit = attachmentAttrs.unit or null;
              in
              if isNonEmptyString kind && isNonEmptyString name && isNonEmptyString unit then
                "${unit}|${kind}|${name}"
              else
                null)
            attachments
        )
    );

  collectRelationEndpointTags = relation: endpointName:
    let
      endpointRaw = relation.${endpointName} or null;
      endpoint = attrsOrEmpty endpointRaw;
      kind = endpoint.kind or null;
    in
    if endpointRaw == "any" then
      [ ]
    else if !builtins.isAttrs endpointRaw then
      [ ]
    else if kind == "tenant" || kind == "service" then
      if isNonEmptyString (endpoint.name or null) then
        [ endpoint.name ]
      else
        [ ]
    else if kind == "external" then
      if isNonEmptyString (endpoint.name or null) then
        [ endpoint.name ]
      else if builtins.isList (endpoint.uplinks or null) then
        builtins.filter isNonEmptyString endpoint.uplinks
      else
        [ ]
    else if kind == "tenant-set" then
      if builtins.isList (endpoint.members or null) then
        builtins.filter isNonEmptyString endpoint.members
      else
        [ ]
    else
      [ ];

  validateRoutes = ifacePath: ifaceAttrs:
    let
      routes = requireAttrs "${ifacePath}.routes" (ifaceAttrs.routes or null);
      _ipv4 = requireList "${ifacePath}.routes.ipv4" (routes.ipv4 or null);
      _ipv6 = requireList "${ifacePath}.routes.ipv6" (routes.ipv6 or null);
    in
    true;

  validateInterface = sitePath: attachmentLookup: links: nodeName: ifName: iface:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      ifaceAttrs = requireAttrs ifacePath iface;
      kind = ifaceAttrs.kind or null;
      interfaceValue = ifaceAttrs.interface or null;
      tenantValue = ifaceAttrs.tenant or null;
      overlayValue = ifaceAttrs.overlay or null;
      upstreamValue = ifaceAttrs.upstream or null;
      linkValue = ifaceAttrs.link or null;
    in
    if !isNonEmptyString kind then
      throw "interface kind is required"
    else if !isNonEmptyString interfaceValue then
      throw "${ifacePath}.interface is required"
    else if kind == "tenant" && !isNonEmptyString tenantValue then
      throw "tenant interface requires explicit tenant"
    else if kind == "tenant" && !hasAttr "${nodeName}|tenant|${tenantValue}" attachmentLookup then
      throw "tenant interface requires explicit site.attachments entry"
    else if kind == "overlay" && !isNonEmptyString overlayValue then
      throw "overlay interface requires explicit overlay"
    else if kind == "wan" && !isNonEmptyString upstreamValue then
      throw "wan interface requires explicit upstream"
    else if kind == "wan" && !isNonEmptyString linkValue then
      throw "wan interface requires explicit link"
    else if kind == "wan" && !hasAttr linkValue links then
      throw "${ifacePath}.link references unknown site link '${linkValue}'"
    else
      builtins.seq
        (validateRoutes ifacePath ifaceAttrs)
        true;

  validateNode = sitePath: attachmentLookup: links: nodeName: node:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath node;
      interfaces = requireAttrs "${nodePath}.interfaces" (nodeAttrs.interfaces or null);
      interfaceNames = sortedNames interfaces;

      hasExplicitTenantInterface =
        builtins.any
          (ifName:
            let
              iface = attrsOrEmpty interfaces.${ifName};
            in
            (iface.kind or null) == "tenant"
            && isNonEmptyString (iface.tenant or null))
          interfaceNames;
    in
    builtins.seq
      (forceAll (
        builtins.map
          (ifName: validateInterface sitePath attachmentLookup links nodeName ifName interfaces.${ifName})
          interfaceNames
      ))
      (if (nodeAttrs.role or null) == "access" && !hasExplicitTenantInterface then
        throw "access node requires at least one tenant interface with explicit tenant"
      else
        true);

  validateCommunicationContract = sitePath: siteAttrs:
    let
      communicationContract = requireAttrs "${sitePath}.communicationContract" (siteAttrs.communicationContract or null);
      allowedRelations = requireList "${sitePath}.communicationContract.allowedRelations" (communicationContract.allowedRelations or null);
      policy = attrsOrEmpty (siteAttrs.policy or null);

      hasPolicyInterfaceTags = builtins.isAttrs (policy.interfaceTags or null);
      hasContractInterfaceTags = builtins.isAttrs (communicationContract.interfaceTags or null);

      interfaceTags =
        if hasContractInterfaceTags then
          communicationContract.interfaceTags
        else
          { };

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
                relation = attrsOrEmpty (builtins.elemAt allowedRelations idx);
              in
              collectRelationEndpointTags relation "from"
              ++ collectRelationEndpointTags relation "to")
            (builtins.length allowedRelations)
        );

      uniqueUnmapped =
        sortedNames (
          builtins.listToAttrs (
            builtins.map
              (tag: {
                name = tag;
                value = true;
              })
              (
                builtins.filter
                  (tag: !hasAttr tag explicitTagSet)
                  referencedTags
              )
          )
        );
    in
    if hasPolicyInterfaceTags && hasContractInterfaceTags then
      throw "exactly one canonical interfaceTags source is allowed; use communicationContract.interfaceTags"
    else if allowedRelations != [ ] && !hasContractInterfaceTags then
      throw "communicationContract.interfaceTags is required"
    else if uniqueUnmapped != [ ] then
      let
        tag = builtins.elemAt uniqueUnmapped 0;
      in
      throw "communicationContract references tag '${tag}' with no explicit interfaceTags mapping"
    else
      true;

  validateBGP = sitePath: siteAttrs:
    let
      bgp = attrsOrEmpty (siteAttrs.bgp or null);
    in
    if (bgp.mode or null) == "bgp" && !builtins.isList (bgp.sessions or null) then
      throw "bgp mode requires explicit site.bgp.sessions"
    else
      true;

  validateSite = enterpriseName: siteName: site:
    let
      sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
      siteAttrs = requireAttrs sitePath site;
      attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);
      links = requireAttrs "${sitePath}.links" (siteAttrs.links or null);
      nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);
      attachmentLookup = attachmentLookupForSite attachments;
    in
    builtins.seq
      (forceAll (
        builtins.map
          (nodeName: validateNode sitePath attachmentLookup links nodeName nodes.${nodeName})
          (sortedNames nodes)
      ))
      (builtins.seq
        (validateCommunicationContract sitePath siteAttrs)
        (validateBGP sitePath siteAttrs));

  validateEnterprises = inputAttrs:
    let
      enterprise = requireAttrs "forwardingModel.enterprise" (inputAttrs.enterprise or null);
    in
    forceAll (
      builtins.map
        (enterpriseName:
          let
            enterpriseAttrs = requireAttrs "forwardingModel.enterprise.${enterpriseName}" enterprise.${enterpriseName};
            sites = requireAttrs "forwardingModel.enterprise.${enterpriseName}.site" (enterpriseAttrs.site or null);
          in
          forceAll (
            builtins.map
              (siteName: validateSite enterpriseName siteName sites.${siteName})
              (sortedNames sites)
          ))
        (sortedNames enterprise)
    );

  inputAttrs = requireAttrs "forwardingModel" forwardingModel;
in
builtins.seq
  (baseValidator inputAttrs)
  (validateEnterprises inputAttrs)
