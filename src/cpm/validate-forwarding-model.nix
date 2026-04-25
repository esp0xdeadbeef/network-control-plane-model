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
    requireStringList
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

  failForwarding = path: message:
    throw "forwarding-model update required: ${path}: ${message}";

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

  collectNamesFromList = list:
    builtins.filter
      isNonEmptyString
      (
        builtins.map
          (item:
            let
              attrs = attrsOrEmpty item;
            in
            attrs.name or null)
          list
      );

  collectStringValues = attrs:
    builtins.filter
      isNonEmptyString
      (builtins.attrValues attrs);

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
      failForwarding ifacePath "interface kind is required"
    else if !isNonEmptyString interfaceValue then
      failForwarding "${ifacePath}.interface" "${ifacePath}.interface is required"
    else if kind == "tenant" && !isNonEmptyString tenantValue then
      failForwarding "${ifacePath}.tenant" "tenant interface requires explicit tenant"
    else if kind == "tenant" && !hasAttr "${nodeName}|tenant|${tenantValue}" attachmentLookup then
      failForwarding
        ifacePath
        "tenant interface requires explicit site.attachments entry; add { kind = \"tenant\"; name = \"${tenantValue}\"; unit = \"${nodeName}\"; } to ${sitePath}.attachments"
    else if kind == "overlay" && !isNonEmptyString overlayValue then
      failForwarding "${ifacePath}.overlay" "overlay interface requires explicit overlay"
    else if kind == "wan" && !isNonEmptyString upstreamValue then
      failForwarding "${ifacePath}.upstream" "wan interface requires explicit upstream"
    else if kind == "wan" && !isNonEmptyString linkValue then
      failForwarding "${ifacePath}.link" "wan interface requires explicit link"
    else if kind == "wan" && !hasAttr linkValue links then
      failForwarding "${ifacePath}.link" "${ifacePath}.link references unknown site link '${linkValue}'"
    else
      builtins.seq
        (validateRoutes ifacePath ifaceAttrs)
        true;

  validateNodeUplink = sitePath: uplinkNameSet: nodeName: uplinkName: uplink:
    let
      uplinkPath = "${sitePath}.nodes.${nodeName}.uplinks.${uplinkName}";
      uplinkAttrs = requireAttrs uplinkPath uplink;

      _knownUplink =
        if hasAttr uplinkName uplinkNameSet then
          true
        else
          failForwarding uplinkPath "node uplink references unknown site uplink '${uplinkName}'";

      _ipv4 =
        if uplinkAttrs ? ipv4 then
          requireStringList "${uplinkPath}.ipv4" uplinkAttrs.ipv4
        else
          true;

      _ipv6 =
        if uplinkAttrs ? ipv6 then
          requireStringList "${uplinkPath}.ipv6" uplinkAttrs.ipv6
        else
          true;
    in
    builtins.seq _knownUplink (builtins.seq _ipv4 _ipv6);

  validateNode = sitePath: attachmentLookup: links: uplinkNameSet: nodeName: node:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath node;

      interfaces = requireAttrs "${nodePath}.interfaces" (nodeAttrs.interfaces or null);
      interfaceNames = sortedNames interfaces;

      uplinks =
        if builtins.isAttrs (nodeAttrs.uplinks or null) then
          nodeAttrs.uplinks
        else
          { };

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
      (builtins.seq
        (forceAll (
          builtins.map
            (uplinkName:
              validateNodeUplink sitePath uplinkNameSet nodeName uplinkName uplinks.${uplinkName})
            (sortedNames uplinks)
        ))
        (if (nodeAttrs.role or null) == "access" && !hasExplicitTenantInterface then
          failForwarding
            "${nodePath}.interfaces"
            "access node requires at least one tenant interface with explicit tenant"
        else
          true));

  validateCommunicationContract = sitePath: siteAttrs:
    let
      communicationContract =
        if siteAttrs ? communicationContract then
          requireAttrs "${sitePath}.communicationContract" siteAttrs.communicationContract
        else
          null;
    in
    if communicationContract == null then
      true
    else
      let
        relationPathRoot =
          if builtins.isList (communicationContract.relations or null) then
            "${sitePath}.communicationContract.relations"
          else
            "${sitePath}.communicationContract.allowedRelations";

        allowedRelations =
          if builtins.isList (communicationContract.relations or null) then
            requireList relationPathRoot communicationContract.relations
          else
            requireList relationPathRoot (communicationContract.allowedRelations or null);

        _legacyContractInterfaceTags =
          if communicationContract ? interfaceTags then
            failForwarding
              "${sitePath}.communicationContract.interfaceTags"
              "communicationContract.interfaceTags is not allowed; use site.policy.interfaceTags"
          else
            true;

        policy =
          if builtins.isAttrs (siteAttrs.policy or null) then
            requireAttrs "${sitePath}.policy" siteAttrs.policy
          else
            failForwarding
              "${sitePath}.policy.interfaceTags"
              "site.policy.interfaceTags is required";

        interfaceTags =
          if builtins.isAttrs (policy.interfaceTags or null) then
            policy.interfaceTags
          else
            failForwarding
              "${sitePath}.policy.interfaceTags"
              "site.policy.interfaceTags is required";

        domains = requireAttrs "${sitePath}.domains" (siteAttrs.domains or null);

        tenantSet =
          makeStringSet (
            collectNamesFromList (
              requireList "${sitePath}.domains.tenants" (domains.tenants or null)
            )
          );

        uplinkNames =
          requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);

        uplinkNameSet =
          makeStringSet uplinkNames;

        externalSet =
          makeStringSet (
            uplinkNames
            ++ collectNamesFromList (
              requireList "${sitePath}.domains.externals" (domains.externals or null)
            )
          );

        serviceSet =
          makeStringSet (
            collectNamesFromList (
              (if builtins.isList (communicationContract.services or null) then
                communicationContract.services
              else
                [ ])
              ++
              (if builtins.isList (siteAttrs.services or null) then
                siteAttrs.services
              else
                [ ])
            )
          );

        explicitTagSet =
          makeStringSet (collectStringValues interfaceTags);

        useExplicitTagMapping =
          sortedNames explicitTagSet != [ ];

        validateExplicitTag = relationPath: tag:
          if hasAttr tag explicitTagSet then
            true
          else
            failForwarding
              "${relationPath}"
              "communicationContract references tag '${tag}' with no explicit site.policy.interfaceTags mapping";

        validateTenantReference = relationPath: endpointPath: tenantName:
          if useExplicitTagMapping then
            validateExplicitTag relationPath tenantName
          else if hasAttr tenantName tenantSet then
            true
          else
            failForwarding endpointPath "communicationContract references unknown tenant '${tenantName}'";

        validateServiceReference = relationPath: endpointPath: serviceName:
          if useExplicitTagMapping then
            validateExplicitTag relationPath serviceName
          else if hasAttr serviceName serviceSet then
            true
          else
            failForwarding endpointPath "communicationContract references unknown service '${serviceName}'";

        validateExternalReference = relationPath: endpointPath: externalName:
          if useExplicitTagMapping then
            validateExplicitTag relationPath externalName
          else if hasAttr externalName externalSet then
            true
          else
            failForwarding endpointPath "communicationContract references unknown external '${externalName}'";

        validateRelationEndpoint = relationIndex: relation: endpointName:
          let
            relationPath = "${relationPathRoot}[${toString relationIndex}]";
            endpointPath = "${relationPath}.${endpointName}";
            endpointRaw = relation.${endpointName} or null;
            endpoint = attrsOrEmpty endpointRaw;
            kind = endpoint.kind or null;
          in
          if endpointRaw == "any" then
            true
          else if !builtins.isAttrs endpointRaw then
            true
          else if kind == "tenant" then
            validateTenantReference relationPath "${endpointPath}.name" (requireString "${endpointPath}.name" (endpoint.name or null))
          else if kind == "service" then
            validateServiceReference relationPath "${endpointPath}.name" (requireString "${endpointPath}.name" (endpoint.name or null))
          else if kind == "external" then
            if isNonEmptyString (endpoint.name or null) then
              validateExternalReference relationPath "${endpointPath}.name" endpoint.name
            else if builtins.isList (endpoint.uplinks or null) then
              forceAll (
                builtins.map
                  (uplinkName:
                    validateExternalReference relationPath "${endpointPath}.uplinks" uplinkName)
                  (requireStringList "${endpointPath}.uplinks" endpoint.uplinks)
              )
            else
              true
          else if kind == "tenant-set" then
            forceAll (
              builtins.map
                (tenantName:
                  validateTenantReference relationPath "${endpointPath}.members" tenantName)
                (requireStringList "${endpointPath}.members" (endpoint.members or null))
            )
          else
            true;
      in
      builtins.seq
        _legacyContractInterfaceTags
        (forceAll (
          builtins.genList
            (relationIndex:
              let
                relation = attrsOrEmpty (builtins.elemAt allowedRelations relationIndex);
              in
              builtins.seq
                (validateRelationEndpoint relationIndex relation "from")
                (validateRelationEndpoint relationIndex relation "to"))
            (builtins.length allowedRelations)
        ));

  validateTransport = sitePath: siteAttrs:
    let
      transport = siteAttrs.transport or null;
    in
    if transport == null then
      true
    else if !builtins.isAttrs transport then
      failForwarding "${sitePath}.transport" "site.transport must be an attribute set"
    else
      let
        overlays = transport.overlays or null;
      in
      if overlays == null || builtins.isAttrs overlays || builtins.isList overlays then
        true
      else
        failForwarding "${sitePath}.transport.overlays" "site.transport.overlays must be an attribute set or list";

  validateSite = enterpriseName: siteName: site:
    let
      sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
      siteAttrs = requireAttrs sitePath site;
      attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);
      links = requireAttrs "${sitePath}.links" (siteAttrs.links or null);
      nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);
      uplinkNameSet =
        makeStringSet (
          requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null)
        );
      attachmentLookup = attachmentLookupForSite attachments;
    in
    builtins.seq
      (validateTransport sitePath siteAttrs)
      (builtins.seq
        (forceAll (
          builtins.map
            (nodeName: validateNode sitePath attachmentLookup links uplinkNameSet nodeName nodes.${nodeName})
            (sortedNames nodes)
        ))
        (validateCommunicationContract sitePath siteAttrs));

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
