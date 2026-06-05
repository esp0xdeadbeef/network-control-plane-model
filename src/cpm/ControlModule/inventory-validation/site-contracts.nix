{ helpers }:

{ forwardingModel }:

let
  inherit (helpers) requireAttrs requireStringList sortedNames;

  attrsOrEmpty = value:
    if builtins.isAttrs value then value else { };

  optional = condition: value:
    if condition then [ value ] else [ ];

  makeStringSet = values:
    builtins.listToAttrs (
      builtins.map
        (value: {
          name = value;
          value = true;
        })
        values
    );

  nodeInterfaceFacts = nodePath: node:
    let
      interfaces = requireAttrs "${nodePath}.interfaces" (node.interfaces or null);
      names = sortedNames interfaces;
      collected =
        builtins.foldl'
          (acc: ifName:
            let
              iface = requireAttrs "${nodePath}.interfaces.${ifName}" interfaces.${ifName};
              kind = iface.kind or null;
            in
            {
              logicalTenantInterfaces =
                acc.logicalTenantInterfaces
                ++ optional (kind == "tenant" && ((iface.logical or false) == true)) ifName;
              p2pLinks =
                acc.p2pLinks
                ++ optional (kind == "p2p" && helpers.isNonEmptyString (iface.link or null)) (iface.link or null);
              wanUpstreams =
                acc.wanUpstreams
                ++ optional (kind == "wan" && helpers.isNonEmptyString (iface.upstream or null)) (iface.upstream or null);
            })
          {
            logicalTenantInterfaces = [ ];
            p2pLinks = [ ];
            wanUpstreams = [ ];
          }
          names;
    in
    {
      inherit interfaces;
      logicalTenantInterfaceSet = makeStringSet collected.logicalTenantInterfaces;
      p2pLinkSet = makeStringSet collected.p2pLinks;
      wanUpstreams = collected.wanUpstreams;
    };

  buildNodeContract = sitePath: nodeName: nodeValue:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      node = requireAttrs nodePath nodeValue;
      interfaceFacts = nodeInterfaceFacts nodePath node;
      egressIntent = attrsOrEmpty (node.egressIntent or null);
      forwardingResponsibility = attrsOrEmpty (node.forwardingResponsibility or null);
      nodeUplinks =
        if builtins.isAttrs (node.uplinks or null) then sortedNames node.uplinks else [ ];
    in
    {
      interfaces = interfaceFacts.interfaces;
      inherit (interfaceFacts) p2pLinkSet logicalTenantInterfaceSet;
      wanUpstreamSet = makeStringSet (interfaceFacts.wanUpstreams ++ nodeUplinks);
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
