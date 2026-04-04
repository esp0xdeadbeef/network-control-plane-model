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
    requireString
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

  validateTransport = sitePath: siteAttrs:
    let
      transport = siteAttrs.transport or null;
    in
    if transport == null then
      true
    else if !builtins.isAttrs transport then
      throw "site.transport must be an attribute set"
    else
      let
        overlays = transport.overlays or null;
      in
      if overlays == null || builtins.isAttrs overlays || builtins.isList overlays then
        true
      else
        throw "site.transport.overlays must be an attribute set or list";

  validateBGPSession = sitePath: nodeSet: sessionIndex: session:
    let
      sessionPath = "${sitePath}.bgp.sessions[${toString sessionIndex}]";
      sessionAttrs = requireAttrs sessionPath session;
      a = requireString "${sessionPath}.a" (sessionAttrs.a or null);
      b = requireString "${sessionPath}.b" (sessionAttrs.b or null);

      _nodeA =
        if hasAttr a nodeSet then
          true
        else
          throw "${sessionPath}.a references unknown node '${a}'";

      _nodeB =
        if hasAttr b nodeSet then
          true
        else
          throw "${sessionPath}.b references unknown node '${b}'";

      _rr =
        if sessionAttrs ? rr then
          let
            rr = requireString "${sessionPath}.rr" (sessionAttrs.rr or null);
          in
          if hasAttr rr nodeSet then
            true
          else
            throw "${sessionPath}.rr references unknown node '${rr}'"
        else
          true;
    in
    builtins.seq _nodeA (builtins.seq _nodeB _rr);

  validateBGP = sitePath: siteAttrs: nodeSet:
    let
      bgp =
        if siteAttrs ? bgp then
          requireAttrs "${sitePath}.bgp" siteAttrs.bgp
        else
          null;
    in
    if bgp == null then
      true
    else if (bgp.mode or null) != "bgp" then
      true
    else
      let
        sessions =
          if builtins.isList (bgp.sessions or null) then
            bgp.sessions
          else
            throw "bgp mode requires explicit site.bgp.sessions";
      in
      if sessions == [ ] then
        throw "bgp mode requires non-empty site.bgp.sessions"
      else
        forceAll (
          builtins.genList
            (sessionIndex:
              validateBGPSession sitePath nodeSet sessionIndex (builtins.elemAt sessions sessionIndex))
            (builtins.length sessions)
        );

  validateSite = enterpriseName: siteName: site:
    let
      sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
      siteAttrs = requireAttrs sitePath site;
      attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);
      links = requireAttrs "${sitePath}.links" (siteAttrs.links or null);
      nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);
      attachmentLookup = attachmentLookupForSite attachments;
      nodeSet = makeStringSet (sortedNames nodes);
    in
    builtins.seq
      (validateTransport sitePath siteAttrs)
      (builtins.seq
        (forceAll (
          builtins.map
            (nodeName: validateNode sitePath attachmentLookup links nodeName nodes.${nodeName})
            (sortedNames nodes)
        ))
        (builtins.seq
          (validateCommunicationContract sitePath siteAttrs)
          (validateBGP sitePath siteAttrs nodeSet)));

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
