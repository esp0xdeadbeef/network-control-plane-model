{ lib }:

{ inventory, cpm }:

let
  isAttrs = builtins.isAttrs;
  isList = builtins.isList;
  isInt = builtins.isInt;
  isString = builtins.isString;

  nonEmptyString = value: isString value && value != "";

  requireAttrs = path: value:
    if isAttrs value then
      value
    else
      throw "inventory lint error: ${path} must be an attribute set";

  requireList = path: value:
    if isList value then
      value
    else
      throw "inventory lint error: ${path} must be a list";

  requireString = path: value:
    if nonEmptyString value then
      value
    else
      throw "inventory lint error: ${path} must be a non-empty string";

  requireInt = path: value:
    if isInt value then
      value
    else
      throw "inventory lint error: ${path} must be an integer";

  attrNames = attrs:
    if isAttrs attrs then
      lib.attrNamesSorted attrs
    else
      [ ];

  optionalAttrs = value:
    if value == null then
      { }
    else if isAttrs value then
      value
    else
      throw "inventory lint error: expected attribute set, got ${builtins.typeOf value}";

  hasAttr = name: attrs:
    isAttrs attrs && builtins.hasAttr name attrs;

  listToSet = names:
    builtins.listToAttrs (
      builtins.map
        (name: {
          inherit name;
          value = true;
        })
        names
    );

  assertNoMixedTopLevelSchema =
    let
      deployment = optionalAttrs (inventory.deployment or null);
      hasHost = hasAttr "host" deployment;
      hasHosts = hasAttr "hosts" deployment;
      hasFabric = hasAttr "fabric" inventory;
      realization = optionalAttrs (inventory.realization or null);
      hasRealizationNodes = hasAttr "nodes" realization;
    in
    if hasHost && hasHosts then
      throw ''
        inventory lint error: deployment.host and deployment.hosts are mutually exclusive.
        Pick exactly one inventory schema.
      ''
    else if hasFabric && hasRealizationNodes then
      throw ''
        inventory lint error: fabric and realization.nodes are mutually exclusive.
        Pick exactly one node realization model.
      ''
    else
      null;

  validateSingularUplink = hostPath: uplink:
    let
      uplinkAttrs = requireAttrs "${hostPath}.uplink" uplink;
      parent =
        if uplinkAttrs ? parent then
          requireString "${hostPath}.uplink.parent" uplinkAttrs.parent
        else
          throw "inventory lint error: ${hostPath}.uplink.parent is required";

      childNames =
        builtins.filter
          (name: name != "parent")
          (attrNames uplinkAttrs);

      _validatedChildren =
        builtins.map
          (childName:
            let
              child = requireAttrs "${hostPath}.uplink.${childName}" uplinkAttrs.${childName};
            in
            if child ? bridge then
              requireString "${hostPath}.uplink.${childName}.bridge" child.bridge
            else
              throw "inventory lint error: ${hostPath}.uplink.${childName}.bridge is required"
          )
          childNames;
    in
    builtins.seq parent true;

  validatePluralUplinks = hostPath: uplinks:
    let
      uplinksAttrs = requireAttrs "${hostPath}.uplinks" uplinks;
      uplinkNames = attrNames uplinksAttrs;

      _validated =
        builtins.map
          (uplinkName:
            let
              uplink = requireAttrs "${hostPath}.uplinks.${uplinkName}" uplinksAttrs.${uplinkName};
              parent =
                if uplink ? parent then
                  requireString "${hostPath}.uplinks.${uplinkName}.parent" uplink.parent
                else
                  throw "inventory lint error: ${hostPath}.uplinks.${uplinkName}.parent is required";

              mode =
                if uplink ? mode then
                  requireString "${hostPath}.uplinks.${uplinkName}.mode" uplink.mode
                else
                  null;

              bridge =
                if uplink ? bridge then
                  requireString "${hostPath}.uplinks.${uplinkName}.bridge" uplink.bridge
                else
                  throw "inventory lint error: ${hostPath}.uplinks.${uplinkName}.bridge is required";

              _vlanCheck =
                if mode != null && mode == "vlan" then
                  if uplink ? vlan then
                    requireInt "${hostPath}.uplinks.${uplinkName}.vlan" uplink.vlan
                  else
                    throw "inventory lint error: ${hostPath}.uplinks.${uplinkName}.vlan is required when mode = \"vlan\""
                else
                  true;
            in
            builtins.seq parent bridge
          )
          uplinkNames;
    in
    builtins.seq _validated true;

  validateBridgeNetworks = hostPath: bridgeNetworks:
    let
      bridges = requireAttrs "${hostPath}.bridgeNetworks" bridgeNetworks;
      _validated =
        builtins.map
          (bridgeName:
            requireAttrs "${hostPath}.bridgeNetworks.${bridgeName}" bridges.${bridgeName})
          (attrNames bridges);
    in
    builtins.seq _validated true;

  validateTransitBridges = hostPath: uplinks: transitBridges:
    let
      uplinkAttrs = requireAttrs "${hostPath}.uplinks" uplinks;
      bridges = requireAttrs "${hostPath}.transitBridges" transitBridges;
      uplinkNames = attrNames uplinkAttrs;

      _validated =
        builtins.map
          (bridgeName:
            let
              bridge = requireAttrs "${hostPath}.transitBridges.${bridgeName}" bridges.${bridgeName};

              _nameCheck =
                if bridge ? name then
                  if bridge.name == bridgeName then
                    true
                  else
                    throw "inventory lint error: ${hostPath}.transitBridges.${bridgeName}.name must equal the attribute name"
                else
                  true;

              _vlanCheck =
                if bridge ? vlan then
                  requireInt "${hostPath}.transitBridges.${bridgeName}.vlan" bridge.vlan
                else
                  throw "inventory lint error: ${hostPath}.transitBridges.${bridgeName}.vlan is required";

              parentUplink =
                if bridge ? parentUplink then
                  requireString "${hostPath}.transitBridges.${bridgeName}.parentUplink" bridge.parentUplink
                else
                  throw "inventory lint error: ${hostPath}.transitBridges.${bridgeName}.parentUplink is required";

              _parentCheck =
                if builtins.elem parentUplink uplinkNames then
                  true
                else
                  throw "inventory lint error: ${hostPath}.transitBridges.${bridgeName}.parentUplink references unknown uplink '${parentUplink}'";
            in
            true
          )
          (attrNames bridges);
    in
    builtins.seq _validated true;

  validateDeployment =
    let
      deployment = optionalAttrs (inventory.deployment or null);
    in
    if deployment == { } then
      {
        family = null;
        hosts = { };
      }
    else if hasAttr "host" deployment then
      let
        hosts = requireAttrs "inventory.deployment.host" deployment.host;
        hostNames = attrNames hosts;

        _validated =
          builtins.map
            (hostName:
              let
                hostPath = "inventory.deployment.host.${hostName}";
                host = requireAttrs hostPath hosts.${hostName};
                _noPlural =
                  if host ? uplinks then
                    throw "inventory lint error: ${hostPath}.uplinks is not allowed in the deployment.host schema"
                  else
                    true;
                _uplink =
                  if host ? uplink then
                    validateSingularUplink hostPath host.uplink
                  else
                    throw "inventory lint error: ${hostPath}.uplink is required";
              in
              true
            )
            hostNames;
      in
      builtins.seq _validated {
        family = "host";
        inherit hosts;
      }
    else if hasAttr "hosts" deployment then
      let
        hosts = requireAttrs "inventory.deployment.hosts" deployment.hosts;
        hostNames = attrNames hosts;

        _validated =
          builtins.map
            (hostName:
              let
                hostPath = "inventory.deployment.hosts.${hostName}";
                host = requireAttrs hostPath hosts.${hostName};

                _noSingular =
                  if host ? uplink then
                    throw "inventory lint error: ${hostPath}.uplink is not allowed in the deployment.hosts schema"
                  else
                    true;

                uplinks =
                  if host ? uplinks then
                    host.uplinks
                  else
                    throw "inventory lint error: ${hostPath}.uplinks is required";

                _uplinks = validatePluralUplinks hostPath uplinks;

                _bridgeNetworks =
                  if host ? bridgeNetworks then
                    validateBridgeNetworks hostPath host.bridgeNetworks
                  else
                    true;

                _transitBridges =
                  if host ? transitBridges then
                    validateTransitBridges hostPath uplinks host.transitBridges
                  else
                    true;
              in
              true
            )
            hostNames;
      in
      builtins.seq _validated {
        family = "hosts";
        inherit hosts;
      }
    else
      throw "inventory lint error: inventory.deployment must contain either deployment.host or deployment.hosts";

  hostBridgeNames = host:
    let
      uplinkBridges =
        if host ? uplinks then
          builtins.filter
            (x: x != null)
            (builtins.map
              (name:
                let
                  uplink = host.uplinks.${name};
                in
                if uplink ? bridge && nonEmptyString uplink.bridge then uplink.bridge else null
              )
              (attrNames host.uplinks))
        else
          [ ];

      bridgeNetworkNames =
        if host ? bridgeNetworks then attrNames host.bridgeNetworks else [ ];

      transitBridgeNames =
        if host ? transitBridges then attrNames host.transitBridges else [ ];
    in
    uplinkBridges ++ bridgeNetworkNames ++ transitBridgeNames;

  validateFabricPort = nodePath: portName: port:
    let
      portPath = "${nodePath}.ports.${portName}";
      portAttrs = requireAttrs portPath port;

      hasLink = portAttrs ? link;
      hasAttachment = portAttrs ? attachment;
      hasKind = portAttrs ? kind;

      kind =
        if hasKind then
          requireString "${portPath}.kind" portAttrs.kind
        else
          null;
    in
    if hasLink == hasAttachment then
      throw ''
        inventory lint error: ${portPath} must declare exactly one of:
          - link
          - attachment
      ''
    else if hasLink then
      let
        _link = requireString "${portPath}.link" portAttrs.link;
        _kind =
          if kind == "p2p" then
            true
          else
            throw "inventory lint error: ${portPath}.kind must be \"p2p\" when ${portPath}.link is set";
        _vlan =
          if portAttrs ? vlan then
            requireInt "${portPath}.vlan" portAttrs.vlan
          else
            throw "inventory lint error: ${portPath}.vlan is required when ${portPath}.kind = \"p2p\"";
      in
      true
    else
      let
        attachment = requireAttrs "${portPath}.attachment" portAttrs.attachment;
        attachKind =
          if attachment ? kind then
            requireString "${portPath}.attachment.kind" attachment.kind
          else
            throw "inventory lint error: ${portPath}.attachment.kind is required";

        _tenantCheck =
          if attachKind == "tenant" then
            if attachment ? name then
              requireString "${portPath}.attachment.name" attachment.name
            else
              throw "inventory lint error: ${portPath}.attachment.name is required when kind = \"tenant\""
          else
            true;

        _hostsCheck =
          if portAttrs ? hosts then
            requireList "${portPath}.hosts" portAttrs.hosts
          else
            true;
      in
      true;

  collectFabricP2PLinkRefs =
    let
      fabric = optionalAttrs (inventory.fabric or null);
      nodeNames = attrNames fabric;

      refsPerNode =
        builtins.map
          (nodeName:
            let
              nodePath = "inventory.fabric.${nodeName}";
              node = requireAttrs nodePath fabric.${nodeName};

              _platform =
                if node ? platform then
                  requireString "${nodePath}.platform" node.platform
                else
                  throw "inventory lint error: ${nodePath}.platform is required";

              ports =
                if node ? ports then
                  requireAttrs "${nodePath}.ports" node.ports
                else
                  throw "inventory lint error: ${nodePath}.ports is required";

              portNames = attrNames ports;

              _validatedPorts =
                builtins.map
                  (portName: validateFabricPort nodePath portName ports.${portName})
                  portNames;

              refs =
                builtins.filter
                  (x: x != null)
                  (builtins.map
                    (portName:
                      let
                        port = ports.${portName};
                      in
                      if (port ? link) && (port.kind or null) == "p2p" then
                        {
                          source = "fabric";
                          node = nodeName;
                          port = portName;
                          link = port.link;
                        }
                      else
                        null
                    )
                    portNames);
            in
            builtins.seq _validatedPorts refs
          )
          nodeNames;
    in
    builtins.concatLists refsPerNode;

  validateRealizationPort = hostBridgesSet: nodePath: portName: port:
    let
      portPath = "${nodePath}.ports.${portName}";
      portAttrs = requireAttrs portPath port;

      _link =
        if portAttrs ? link then
          requireString "${portPath}.link" portAttrs.link
        else
          throw "inventory lint error: ${portPath}.link is required";

      attach =
        if portAttrs ? attach then
          requireAttrs "${portPath}.attach" portAttrs.attach
        else
          throw "inventory lint error: ${portPath}.attach is required";

      kind =
        if attach ? kind then
          requireString "${portPath}.attach.kind" attach.kind
        else
          throw "inventory lint error: ${portPath}.attach.kind is required";

      _attachCheck =
        if kind == "bridge" then
          let
            bridge =
              if attach ? bridge then
                requireString "${portPath}.attach.bridge" attach.bridge
              else
                throw "inventory lint error: ${portPath}.attach.bridge is required when attach.kind = \"bridge\"";
          in
          if hasAttr bridge hostBridgesSet then
            true
          else
            throw "inventory lint error: ${portPath}.attach.bridge references unknown bridge '${bridge}'"
        else
          true;

      interface =
        if portAttrs ? interface then
          requireAttrs "${portPath}.interface" portAttrs.interface
        else
          throw "inventory lint error: ${portPath}.interface is required";

      _ifName =
        if interface ? name then
          requireString "${portPath}.interface.name" interface.name
        else
          throw "inventory lint error: ${portPath}.interface.name is required";
    in
    true;

  collectRealizationLinkRefs = deploymentInfo:
    let
      realization = optionalAttrs (inventory.realization or null);
      nodes = optionalAttrs (realization.nodes or null);
      nodeNames = attrNames nodes;
      hostNames = attrNames deploymentInfo.hosts;

      refsPerNode =
        builtins.map
          (nodeName:
            let
              nodePath = "inventory.realization.nodes.${nodeName}";
              node = requireAttrs nodePath nodes.${nodeName};

              hostName =
                if node ? host then
                  requireString "${nodePath}.host" node.host
                else
                  throw "inventory lint error: ${nodePath}.host is required";

              _hostExists =
                if builtins.elem hostName hostNames then
                  true
                else
                  throw "inventory lint error: ${nodePath}.host references unknown deployment host '${hostName}'";

              _platform =
                if node ? platform then
                  requireString "${nodePath}.platform" node.platform
                else
                  throw "inventory lint error: ${nodePath}.platform is required";

              ports =
                if node ? ports then
                  requireAttrs "${nodePath}.ports" node.ports
                else
                  throw "inventory lint error: ${nodePath}.ports is required";

              hostDef = deploymentInfo.hosts.${hostName};
              hostBridgesSet = listToSet (hostBridgeNames hostDef);

              portNames = attrNames ports;

              _validatedPorts =
                builtins.map
                  (portName:
                    validateRealizationPort hostBridgesSet nodePath portName ports.${portName})
                  portNames;

              refs =
                builtins.map
                  (portName:
                    {
                      source = "realization";
                      node = nodeName;
                      port = portName;
                      link = ports.${portName}.link;
                    })
                  portNames;
            in
            builtins.seq _validatedPorts refs
          )
          nodeNames;
    in
    builtins.concatLists refsPerNode;

  collectCPMP2PLinks =
    let
      data = requireAttrs "control_plane_model.data" (cpm.data or null);

      enterpriseNames = attrNames data;

      perEnterprise =
        builtins.map
          (enterpriseName:
            let
              sites = requireAttrs "control_plane_model.data.${enterpriseName}" data.${enterpriseName};
              siteNames = attrNames sites;

              perSite =
                builtins.map
                  (siteName:
                    let
                      site = requireAttrs "control_plane_model.data.${enterpriseName}.${siteName}" sites.${siteName};
                      transit = requireAttrs "control_plane_model.data.${enterpriseName}.${siteName}.transit" (site.transit or null);
                      adjacencies = requireList "control_plane_model.data.${enterpriseName}.${siteName}.transit.adjacencies" (transit.adjacencies or null);

                      names =
                        builtins.filter
                          (x: x != null)
                          (builtins.map
                            (adj:
                              if (adj.kind or null) == "p2p" then
                                if adj ? link && nonEmptyString adj.link then
                                  adj.link
                                else if adj ? name && nonEmptyString adj.name then
                                  adj.name
                                else
                                  throw "inventory lint error: CPM p2p adjacency is missing link/name"
                              else
                                null
                            )
                            adjacencies);
                    in
                    names
                  )
                  siteNames;
            in
            builtins.concatLists perSite
          )
          enterpriseNames;
    in
    builtins.concatLists perEnterprise;

  validateDeclaredRefsExistInCPM = refs:
    let
      cpmLinkSet = listToSet collectCPMP2PLinks;

      unknownRefs =
        builtins.filter
          (ref: !(hasAttr ref.link cpmLinkSet))
          refs;
    in
    if unknownRefs != [ ] then
      throw ''
        inventory lint error: inventory references p2p link names not present in control_plane_model transit.
        Unknown references:
        ${builtins.toJSON unknownRefs}
      ''
    else
      true;

  validateFullP2PCoverage = refs:
    let
      cpmLinks = collectCPMP2PLinks;

      counts =
        builtins.foldl'
          (acc: ref:
            acc
            // {
              ${ref.link} = (acc.${ref.link} or 0) + 1;
            })
          { }
          refs;

      badCounts =
        builtins.filter
          (item: item.count != 2)
          (builtins.map
            (linkName: {
              link = linkName;
              count = counts.${linkName} or 0;
            })
            cpmLinks);

      missing =
        builtins.filter
          (item: item.count == 0)
          badCounts;

      incomplete =
        builtins.filter
          (item: item.count == 1)
          badCounts;

      overRealized =
        builtins.filter
          (item: item.count > 2)
          badCounts;
    in
    if missing != [ ] then
      throw ''
        inventory lint error: missing explicit inventory realization for required p2p transit links.
        Missing links:
        ${builtins.toJSON missing}
      ''
    else if incomplete != [ ] then
      throw ''
        inventory lint error: p2p transit links must be realized exactly twice in inventory.
        Incomplete links:
        ${builtins.toJSON incomplete}
      ''
    else if overRealized != [ ] then
      throw ''
        inventory lint error: p2p transit links may not be realized more than twice in inventory.
        Over-realized links:
        ${builtins.toJSON overRealized}
      ''
    else
      true;

  inventoryAttrs =
    if inventory == { } then
      { }
    else
      requireAttrs "inventory" inventory;

  deploymentInfo =
    if inventoryAttrs == { } then
      {
        family = null;
        hosts = { };
      }
    else
      let
        _schema = assertNoMixedTopLevelSchema;
      in
      builtins.seq _schema validateDeployment;

  fabricP2PRefs =
    if inventoryAttrs ? fabric then
      collectFabricP2PLinkRefs
    else
      [ ];

  realizationRefs =
    if inventoryAttrs ? realization then
      collectRealizationLinkRefs deploymentInfo
    else
      [ ];

  allRefs = fabricP2PRefs ++ realizationRefs;
in
if inventoryAttrs == { } then
  true
else
  builtins.seq deploymentInfo (
    builtins.seq (validateDeclaredRefsExistInCPM allRefs) (
      validateFullP2PCoverage allRefs
    )
  )
