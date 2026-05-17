{ helpers }:

{ forwardingModel, inventory ? { }, realizationIndex }:

let
  inherit (helpers)
    forceAll
    hasAttr
    requireAttrs
    requireStringList
    sortedNames
    ;

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

  failInventory = path: message:
    throw "inventory lint error: ${path}: ${message}";

  buildNodeContract = sitePath: nodeName: nodeValue:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      node = requireAttrs nodePath nodeValue;
      interfaces = requireAttrs "${nodePath}.interfaces" (node.interfaces or null);
      interfaceNames = sortedNames interfaces;

      p2pLinks =
        builtins.filter
          helpers.isNonEmptyString
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
          helpers.isNonEmptyString
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
          helpers.isNonEmptyString
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
                  inherit
                    enterpriseName
                    siteName
                    sitePath
                    links
                    nodes
                    uplinkNames
                    ;
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
              })
            (sortedNames sites))
        (sortedNames enterpriseRoot)
    );

  sitesByKey = builtins.listToAttrs siteEntries;

  validatePortBinding = targetDef: siteContract: nodeContract: portName:
    let
      portPath = "${targetDef.nodePath}.ports.${portName}";
      portBinding = targetDef.portBindings.portDefs.${portName};
      selector = portBinding.selector;
      nodeName = targetDef.logical.name;
    in
    if selector.kind == "link" then
      if !hasAttr selector.key siteContract.links then
        failInventory "${portPath}.link" "references unknown forwarding-model site link '${selector.key}'"
      else
        let
          link = siteContract.links.${selector.key};
        in
        if (link.kind or null) != "p2p" then
          failInventory "${portPath}.link" "link selector must reference a p2p forwarding-model link; use uplink selectors for WAN realization"
        else if !hasAttr selector.key nodeContract.p2pLinkSet then
          failInventory "${portPath}.link" "logical node '${nodeName}' does not declare p2p link '${selector.key}'"
        else
          true
    else if selector.kind == "logicalInterface" then
      if !hasAttr selector.key nodeContract.interfaces then
        failInventory "${portPath}.logicalInterface" "references unknown logical interface '${selector.key}' on node '${nodeName}'"
      else if !hasAttr selector.key nodeContract.logicalTenantInterfaceSet then
        failInventory "${portPath}.logicalInterface" "must reference a tenant interface with logical = true"
      else
        true
    else if !hasAttr selector.key siteContract.uplinkNameSet then
      failInventory "${portPath}.uplink" "references unknown site uplink '${selector.key}'"
    else if !nodeContract.mayAnchorExternalUplinks then
      failInventory "${portPath}.uplink" "logical node '${nodeName}' is not allowed to anchor external uplinks"
    else if !hasAttr selector.key nodeContract.wanUpstreamSet then
      failInventory "${portPath}.uplink" "logical node '${nodeName}' does not declare WAN uplink '${selector.key}'"
    else
      true;

  validateRealizedTarget = targetName:
    let
      targetDef = realizationIndex.targetDefs.${targetName};
      logical = targetDef.logical;
      siteKey = "${logical.enterprise}|${logical.site}";
      siteContract =
        if hasAttr siteKey sitesByKey then
          sitesByKey.${siteKey}
        else
          failInventory "${targetDef.nodePath}.logicalNode" "references unknown forwarding-model site '${logical.enterprise}.${logical.site}'";

      nodeContract =
        if hasAttr logical.name siteContract.nodeContracts then
          siteContract.nodeContracts.${logical.name}
        else
          failInventory "${targetDef.nodePath}.logicalNode.name" "references unknown forwarding-model node '${logical.name}'";
    in
    forceAll (
      builtins.map
        (portName:
          validatePortBinding targetDef siteContract nodeContract portName)
        (sortedNames targetDef.portBindings.portDefs)
    );

  unrealizedRuntimeTargets =
    builtins.concatLists (
      builtins.map
        (siteKey:
          let
            siteContract = sitesByKey.${siteKey};
          in
          builtins.map
            (nodeName:
              {
                path = "${siteContract.sitePath}.nodes.${nodeName}";
                runtimeTarget = nodeName;
                actualPlacementKind = "missing-inventory-realization";
                expectedPlacementKind = "inventory-realization";
                logicalNode = {
                  enterprise = siteContract.enterpriseName;
                  site = siteContract.siteName;
                  name = nodeName;
                };
              })
            (builtins.filter
              (nodeName:
                let
                  logicalKey = "${siteContract.enterpriseName}|${siteContract.siteName}|${nodeName}";
                in
                  !hasAttr logicalKey realizationIndex.byLogical)
              (sortedNames siteContract.nodeContracts)))
        (sortedNames sitesByKey)
    );

  validateRuntimeTargetCoverage =
    if unrealizedRuntimeTargets != [ ] then
      throw ''
        inventory lint error: inventory.nix must explicitly realize every control_plane_model runtime target via inventory.realization.nodes.
        Missing runtime target realizations:
        ${builtins.toJSON unrealizedRuntimeTargets}
      ''
    else
      true;
in
builtins.seq
  (forceAll (
    builtins.map
      validateRealizedTarget
      (sortedNames realizationIndex.targetDefs)
  ))
  validateRuntimeTargetCoverage
