{ helpers }:

{ forwardingModel }:

let
  inherit (helpers) requireAttrs requireStringList sortedNames;

  attrsOrEmpty = value:
    if builtins.isAttrs value then value else { };

  makeStringSet = values:
    builtins.listToAttrs (
      builtins.map
        (value: {
          name = value;
          value = true;
        })
        values
    );

  nodeInterfaceNames = nodePath: node:
    let
      interfaces = requireAttrs "${nodePath}.interfaces" (node.interfaces or null);
    in
    {
      inherit interfaces;
      names = sortedNames interfaces;
    };

  nodeInterfaceSet = predicate: interfaceData:
    makeStringSet (
      builtins.filter helpers.isNonEmptyString (
        builtins.map
          (ifName:
            let
              iface = interfaceData.interfaces.${ifName};
            in
            if predicate ifName iface then ifName else null)
          interfaceData.names
      )
    );

  p2pLinkSet = nodePath: interfaceData:
    makeStringSet (
      builtins.filter helpers.isNonEmptyString (
        builtins.map
          (ifName:
            let
              iface = requireAttrs "${nodePath}.interfaces.${ifName}" interfaceData.interfaces.${ifName};
            in
            if (iface.kind or null) == "p2p" then iface.link or null else null)
          interfaceData.names
      )
    );

  wanUpstreamSet = node: nodePath: interfaceData:
    let
      interfaceWanUpstreams =
        builtins.filter helpers.isNonEmptyString (
          builtins.map
            (ifName:
              let
                iface = requireAttrs "${nodePath}.interfaces.${ifName}" interfaceData.interfaces.${ifName};
              in
              if (iface.kind or null) == "wan" then iface.upstream or null else null)
            interfaceData.names
        );
      nodeUplinks =
        if builtins.isAttrs (node.uplinks or null) then sortedNames node.uplinks else [ ];
    in
    makeStringSet (interfaceWanUpstreams ++ nodeUplinks);

  buildNodeContract = sitePath: nodeName: nodeValue:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      node = requireAttrs nodePath nodeValue;
      interfaceData = nodeInterfaceNames nodePath node;
      egressIntent = attrsOrEmpty (node.egressIntent or null);
      forwardingResponsibility = attrsOrEmpty (node.forwardingResponsibility or null);
    in
    {
      interfaces = interfaceData.interfaces;
      p2pLinkSet = p2pLinkSet nodePath interfaceData;
      logicalTenantInterfaceSet = nodeInterfaceSet
        (_ifName: iface: (iface.kind or null) == "tenant" && ((iface.logical or false) == true))
        interfaceData;
      wanUpstreamSet = wanUpstreamSet node nodePath interfaceData;
      mayAnchorExternalUplinks =
        (egressIntent.exit or false) == true
        || (forwardingResponsibility.anchorsExternalUplinks or false) == true;
    };

  buildSiteContract = enterpriseName: enterprisePath: siteName: siteValue:
    let
      sitePath = "${enterprisePath}.site.${siteName}";
      site = requireAttrs sitePath siteValue;
      links = requireAttrs "${sitePath}.links" (site.links or null);
      nodes = requireAttrs "${sitePath}.nodes" (site.nodes or null);
      uplinkNames = requireStringList "${sitePath}.uplinkNames" (site.uplinkNames or null);
    in
    {
      name = "${enterpriseName}|${siteName}";
      value = {
        inherit enterpriseName siteName sitePath links nodes uplinkNames;
        uplinkNameSet = makeStringSet uplinkNames;
        nodeContracts =
          builtins.listToAttrs (
            builtins.map
              (nodeName: {
                name = nodeName;
                value = buildNodeContract sitePath nodeName nodes.${nodeName};
              })
              (sortedNames nodes)
          );
      };
    };

  enterpriseRoot = requireAttrs "forwardingModel.enterprise" (forwardingModel.enterprise or null);
in
builtins.listToAttrs (
  builtins.concatLists (
    builtins.map
      (enterpriseName:
      let
        enterprisePath = "forwardingModel.enterprise.${enterpriseName}";
        enterpriseValue = requireAttrs enterprisePath enterpriseRoot.${enterpriseName};
        sites = requireAttrs "${enterprisePath}.site" (enterpriseValue.site or null);
      in
      builtins.map
        (siteName: buildSiteContract enterpriseName enterprisePath siteName sites.${siteName})
        (sortedNames sites))
      (sortedNames enterpriseRoot)
  )
)
