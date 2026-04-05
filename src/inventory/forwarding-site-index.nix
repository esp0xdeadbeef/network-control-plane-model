{ helpers }:

forwardingModel:

let
  inherit (helpers)
    isNonEmptyString
    requireAttrs
    requireStringList
    sortedNames;

  attrsOrEmpty = value:
    if builtins.isAttrs value then
      value
    else
      { };

  makeStringSet = values:
    builtins.listToAttrs (
      builtins.map
        (value: {
          name = value;
          value = true;
        })
        values
    );

  buildNodeContract = sitePath: nodeName: nodeValue:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      node = requireAttrs nodePath nodeValue;
      interfaces = requireAttrs "${nodePath}.interfaces" (node.interfaces or null);
      interfaceNames = sortedNames interfaces;

      p2pLinks =
        builtins.filter
          isNonEmptyString
          (builtins.map
            (ifName:
              let
                iface = requireAttrs "${nodePath}.interfaces.${ifName}" interfaces.${ifName};
              in
              if (iface.kind or null) == "p2p" then
                iface.link or null
              else
                null)
            interfaceNames);

      logicalTenantInterfaces =
        builtins.filter
          isNonEmptyString
          (builtins.map
            (ifName:
              let
                iface = requireAttrs "${nodePath}.interfaces.${ifName}" interfaces.${ifName};
              in
              if (iface.kind or null) == "tenant" && ((iface.logical or false) == true) then
                ifName
              else
                null)
            interfaceNames);

      interfaceWanUpstreams =
        builtins.filter
          isNonEmptyString
          (builtins.map
            (ifName:
              let
                iface = requireAttrs "${nodePath}.interfaces.${ifName}" interfaces.${ifName};
              in
              if (iface.kind or null) == "wan" then
                iface.upstream or null
              else
                null)
            interfaceNames);

      nodeUplinks =
        if builtins.isAttrs (node.uplinks or null) then
          sortedNames node.uplinks
        else
          [ ];

      egressIntent = attrsOrEmpty (node.egressIntent or null);
      forwardingResponsibility = attrsOrEmpty (node.forwardingResponsibility or null);
    in
    {
      interfaces = interfaces;
      p2pLinkSet = makeStringSet p2pLinks;
      logicalTenantInterfaceSet = makeStringSet logicalTenantInterfaces;
      wanUpstreamSet = makeStringSet (interfaceWanUpstreams ++ nodeUplinks);
      mayAnchorExternalUplinks =
        (egressIntent.exit or false) == true
        || (forwardingResponsibility.anchorsExternalUplinks or false) == true;
    };

  enterpriseRoot =
    requireAttrs "forwardingModel.enterprise" (forwardingModel.enterprise or null);

  siteEntries =
    builtins.concatLists (
      builtins.map
        (enterpriseName:
          let
            enterprisePath = "forwardingModel.enterprise.${enterpriseName}";
            enterpriseValue = requireAttrs enterprisePath enterpriseRoot.${enterpriseName};
            sites = requireAttrs "${enterprisePath}.site" (enterpriseValue.site or null);
          in
          builtins.map
            (siteName:
              let
                sitePath = "${enterprisePath}.site.${siteName}";
                site = requireAttrs sitePath sites.${siteName};
                links = requireAttrs "${sitePath}.links" (site.links or null);
                nodes = requireAttrs "${sitePath}.nodes" (site.nodes or null);
                uplinkNames = requireStringList "${sitePath}.uplinkNames" (site.uplinkNames or null);
              in
              {
                name = "${enterpriseName}|${siteName}";
                value = {
                  enterpriseName = enterpriseName;
                  siteName = siteName;
                  sitePath = sitePath;
                  links = links;
                  uplinkNames = uplinkNames;
                  uplinkNameSet = makeStringSet uplinkNames;
                  nodes =
                    builtins.listToAttrs (
                      builtins.map
                        (nodeName: {
                          name = nodeName;
                          value = buildNodeContract sitePath nodeName nodes.${nodeName};
                        })
                        (sortedNames nodes)
                    );
                };
              })
            (sortedNames sites))
        (sortedNames enterpriseRoot)
    );
in
{
  sitesByKey = builtins.listToAttrs siteEntries;
}
