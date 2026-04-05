{ helpers, inventory }:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    logicalKey
    optionalAttrs
    requireAttrs
    requireString
    sortedNames;

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  inventoryRoot = optionalAttrs inventory;
  deploymentRoot = optionalAttrs (inventoryRoot.deployment or null);
  realizationRoot = optionalAttrs (inventoryRoot.realization or null);

  _legacyFabric =
    if inventoryRoot ? fabric then
      failInventory "inventory.fabric" "legacy inventory.fabric is not supported; use inventory.realization.nodes"
    else
      true;

  _legacyDeploymentHost =
    if deploymentRoot ? host then
      failInventory "inventory.deployment.host" "legacy deployment.host is not supported; use inventory.deployment.hosts"
    else
      true;

  _legacyRealizationLinks =
    if realizationRoot ? links then
      failInventory "inventory.realization.links" "legacy realization.links is not supported; declare selectors directly in inventory.realization.nodes.<target>.ports"
    else
      true;

  requireInt = path: value:
    if builtins.isInt value then
      value
    else
      failInventory path "must be an integer";

  validateFamilyMethod = path: value:
    let
      attrs = requireAttrs path value;
    in
    requireString "${path}.method" (attrs.method or null);

  buildHostData = hostName: hostValue:
    let
      hostPath = "inventory.deployment.hosts.${hostName}";
      host = requireAttrs hostPath hostValue;
      uplinks = requireAttrs "${hostPath}.uplinks" (host.uplinks or null);
      uplinkNames = sortedNames uplinks;

      uplinkDataEntries =
        builtins.map
          (uplinkName:
            let
              uplinkPath = "${hostPath}.uplinks.${uplinkName}";
              uplink = requireAttrs uplinkPath uplinks.${uplinkName};
              parent = requireString "${uplinkPath}.parent" (uplink.parent or null);
              bridge = requireString "${uplinkPath}.bridge" (uplink.bridge or null);

              _modeCheck =
                if builtins.isString (uplink.mode or null) && uplink.mode != "" then
                  requireString "${uplinkPath}.mode" uplink.mode
                else
                  true;

              _vlanCheck =
                if (uplink.mode or null) == "vlan" then
                  requireInt "${uplinkPath}.vlan" (uplink.vlan or null)
                else
                  true;

              _ipv4Check =
                if builtins.isAttrs (uplink.ipv4 or null) then
                  validateFamilyMethod "${uplinkPath}.ipv4" uplink.ipv4
                else
                  true;

              _ipv6Check =
                if builtins.isAttrs (uplink.ipv6 or null) then
                  validateFamilyMethod "${uplinkPath}.ipv6" uplink.ipv6
                else
                  true;

              value = {
                uplinkName = uplinkName;
                bridge = bridge;
                ipv4 =
                  if builtins.isAttrs (uplink.ipv4 or null) then
                    uplink.ipv4
                  else
                    null;
                ipv6 =
                  if builtins.isAttrs (uplink.ipv6 or null) then
                    uplink.ipv6
                  else
                    null;
              };
            in
            builtins.seq
              parent
              (builtins.seq
                _modeCheck
                (builtins.seq
                  _vlanCheck
                  (builtins.seq
                    _ipv4Check
                    (builtins.seq
                      _ipv6Check
                      {
                        name = uplinkName;
                        value = value;
                      })))))
          uplinkNames;

      uplinkByName =
        builtins.listToAttrs uplinkDataEntries;

      uplinkByBridge =
        ensureUniqueEntries
          "${hostPath}.uplinks[*].bridge"
          (
            builtins.map
              (entry: {
                name = entry.value.bridge;
                value = entry.value;
              })
              uplinkDataEntries
          );

      bridgeNetworks =
        if builtins.isAttrs (host.bridgeNetworks or null) then
          let
            networks = host.bridgeNetworks;
            _validated =
              builtins.map
                (bridgeName:
                  requireAttrs "${hostPath}.bridgeNetworks.${bridgeName}" networks.${bridgeName})
                (sortedNames networks);
          in
          builtins.seq _validated networks
        else
          { };

      transitBridges =
        if builtins.isAttrs (host.transitBridges or null) then
          let
            bridges = host.transitBridges;
            _validated =
              builtins.map
                (bridgeName:
                  let
                    bridgePath = "${hostPath}.transitBridges.${bridgeName}";
                    bridge = requireAttrs bridgePath bridges.${bridgeName};
                    parentUplink =
                      requireString
                        "${bridgePath}.parentUplink"
                        (bridge.parentUplink or null);

                    _nameCheck =
                      if bridge ? name then
                        if bridge.name == bridgeName then
                          true
                        else
                          failInventory "${bridgePath}.name" "must equal the attribute name"
                      else
                        true;

                    _vlanCheck =
                      requireInt "${bridgePath}.vlan" (bridge.vlan or null);

                    _parentCheck =
                      if builtins.elem parentUplink uplinkNames then
                        true
                      else
                        failInventory "${bridgePath}.parentUplink" "references unknown uplink '${parentUplink}'";
                  in
                  builtins.seq _nameCheck (builtins.seq _vlanCheck _parentCheck))
                (sortedNames bridges);
          in
          builtins.seq _validated bridges
        else
          { };

      hostBridgeSet =
        builtins.listToAttrs (
          builtins.map
            (bridgeName: {
              name = bridgeName;
              value = true;
            })
            (
              (sortedNames uplinkByBridge)
              ++ (sortedNames bridgeNetworks)
              ++ (sortedNames transitBridges)
            )
        );
    in
    {
      hostPath = hostPath;
      uplinkByName = uplinkByName;
      uplinkByBridge = uplinkByBridge;
      hostBridgeSet = hostBridgeSet;
    };

  deploymentHostsRaw =
    if builtins.isAttrs (deploymentRoot.hosts or null) then
      deploymentRoot.hosts
    else
      { };

  deploymentHosts =
    builtins.seq
      _legacyDeploymentHost
      (builtins.listToAttrs (
        builtins.map
          (hostName: {
            name = hostName;
            value = buildHostData hostName deploymentHostsRaw.${hostName};
          })
          (sortedNames deploymentHostsRaw)
      ));

  selectPortTarget = portPath: port:
    let
      linkValue =
        if builtins.isString (port.link or null) && port.link != "" then
          port.link
        else
          null;

      logicalInterfaceValue =
        if builtins.isString (port.logicalInterface or null) && port.logicalInterface != "" then
          port.logicalInterface
        else
          null;

      uplinkValue =
        if builtins.isString (port.uplink or null) && port.uplink != "" then
          port.uplink
        else
          null;

      hostUplinkValue =
        if builtins.isString (port.upstream or null) && port.upstream != "" then
          port.upstream
        else
          null;

      selectors =
        builtins.filter
          (selector: selector != null)
          [
            (if logicalInterfaceValue != null then { kind = "logicalInterface"; key = logicalInterfaceValue; } else null)
            (if uplinkValue != null then { kind = "uplink"; key = uplinkValue; } else null)
            (if linkValue != null && hostUplinkValue != null && uplinkValue == null then { kind = "uplink"; key = linkValue; } else null)
            (if linkValue != null && hostUplinkValue == null then { kind = "link"; key = linkValue; } else null)
          ];
    in
    if builtins.length selectors != 1 then
      failInventory portPath "must declare exactly one of link, logicalInterface, uplink"
    else
      builtins.elemAt selectors 0;

  normalizePortBinding = nodePath: hostData: portName: portValue:
    let
      portPath = "${nodePath}.ports.${portName}";
      port = requireAttrs portPath portValue;

      selector = selectPortTarget portPath port;
      attach = requireAttrs "${portPath}.attach" (port.attach or null);
      interface = requireAttrs "${portPath}.interface" (port.interface or null);

      runtimeIfName =
        requireString "${portPath}.interface.name" (interface.name or null);

      _attachKind =
        requireString "${portPath}.attach.kind" (attach.kind or null);

      _attachBridge =
        if (attach.kind or null) == "bridge" then
          let
            bridge =
              requireString "${portPath}.attach.bridge" (attach.bridge or null);
          in
          if hasAttr bridge hostData.hostBridgeSet then
            true
          else
            failInventory "${portPath}.attach.bridge" "references unknown bridge '${bridge}'"
        else
          true;

      bridgeName =
        if builtins.isString (attach.bridge or null) && attach.bridge != "" then
          attach.bridge
        else
          null;

      explicitHostUplinkName =
        if builtins.isString (port.upstream or null) && port.upstream != "" then
          port.upstream
        else
          null;

      explicitHostUplink =
        if explicitHostUplinkName == null then
          null
        else if hasAttr explicitHostUplinkName hostData.uplinkByName then
          hostData.uplinkByName.${explicitHostUplinkName}
        else
          failInventory "${portPath}.upstream" "references unknown host uplink '${explicitHostUplinkName}'";

      bridgeResolvedHostUplink =
        if bridgeName != null && hasAttr bridgeName hostData.uplinkByBridge then
          hostData.uplinkByBridge.${bridgeName}
        else
          null;

      _hostUplinkBridgeMatch =
        if explicitHostUplink != null && bridgeResolvedHostUplink != null then
          if explicitHostUplink.uplinkName == bridgeResolvedHostUplink.uplinkName then
            true
          else
            failInventory "${portPath}.upstream" "does not match host uplink resolved from attach.bridge '${bridgeName}'"
        else
          true;

      hostUplink =
        if explicitHostUplink != null then
          explicitHostUplink
        else
          bridgeResolvedHostUplink;

      _uplinkHostBinding =
        if selector.kind == "uplink" && hostUplink == null then
          failInventory "${portPath}.upstream" "uplink realization must explicitly resolve a host uplink via upstream or attach.bridge"
        else
          true;
    in
    builtins.seq
      _attachKind
      (builtins.seq
        _attachBridge
        (builtins.seq
          _hostUplinkBridgeMatch
          (builtins.seq
            _uplinkHostBinding
            {
              name = portName;
              value = {
                runtimePort = portName;
                runtimeIfName = runtimeIfName;
                attach = attach;
                hostUplink = hostUplink;
                selector = selector;
              };
            })));

  buildPortBindings = nodePath: hostData: ports:
    let
      portDefs =
        builtins.listToAttrs (
          builtins.map
            (portName:
              normalizePortBinding nodePath hostData portName ports.${portName})
            (sortedNames ports)
        );

      insertBinding = acc: portName:
        let
          binding = portDefs.${portName};
          selector = binding.selector;
          bucketName =
            if selector.kind == "link" then
              "byLink"
            else if selector.kind == "logicalInterface" then
              "byLogicalInterface"
            else
              "byUplink";

          existingBucket = acc.${bucketName};
        in
        if hasAttr selector.key existingBucket then
          failInventory "${nodePath}.ports.${portName}" "selector '${selector.kind}=${selector.key}' is realized more than once on the same runtime target"
        else
          acc
          // {
            ${bucketName} =
              existingBucket
              // {
                ${selector.key} = binding;
              };
          };
    in
    (builtins.foldl'
      insertBinding
      {
        byLink = { };
        byLogicalInterface = { };
        byUplink = { };
      }
      (sortedNames portDefs))
    // {
      portDefs = portDefs;
    };

  realizationNodes =
    if builtins.isAttrs (realizationRoot.nodes or null) then
      realizationRoot.nodes
    else
      { };
in
builtins.seq
  _legacyFabric
  (builtins.seq
    _legacyRealizationLinks
    (builtins.foldl'
      (acc: targetName:
        let
          nodePath = "inventory.realization.nodes.${targetName}";
          node = requireAttrs nodePath realizationNodes.${targetName};
          hostName = requireString "${nodePath}.host" (node.host or null);

          hostData =
            if hasAttr hostName deploymentHosts then
              deploymentHosts.${hostName}
            else
              failInventory "${nodePath}.host" "references unknown deployment host '${hostName}'";

          _platform =
            requireString "${nodePath}.platform" (node.platform or null);

          logicalNode =
            requireAttrs "${nodePath}.logicalNode" (node.logicalNode or null);

          logical = {
            enterprise =
              requireString "${nodePath}.logicalNode.enterprise" (logicalNode.enterprise or null);
            site =
              requireString "${nodePath}.logicalNode.site" (logicalNode.site or null);
            name =
              requireString "${nodePath}.logicalNode.name" (logicalNode.name or null);
          };

          key = logicalKey logical;

          ports =
            requireAttrs "${nodePath}.ports" (node.ports or null);

          portBindings =
            buildPortBindings nodePath hostData ports;
        in
        if hasAttr key acc.byLogical then
          failInventory nodePath "logical node '${key}' is realized by multiple runtime targets"
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
                  portBindings = portBindings;
                };
              };
          })
      {
        byLogical = { };
        targetDefs = { };
      }
      (sortedNames realizationNodes)))
