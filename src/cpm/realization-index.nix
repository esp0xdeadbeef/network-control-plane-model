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

  inventoryRoot = optionalAttrs inventory;
  deploymentRoot = optionalAttrs (inventoryRoot.deployment or null);
  deploymentHosts = optionalAttrs (deploymentRoot.hosts or null);
  realizationRoot = optionalAttrs (inventoryRoot.realization or null);
  realizationNodes = optionalAttrs (realizationRoot.nodes or null);

  buildHostUplinkByBridge = hostPath: host:
    let
      uplinks = optionalAttrs (host.uplinks or null);
      uplinkNames = sortedNames uplinks;

      entries =
        builtins.map
          (uplinkName:
            let
              uplinkPath = "${hostPath}.uplinks.${uplinkName}";
              uplink = requireAttrs uplinkPath uplinks.${uplinkName};
              bridge = requireString "${uplinkPath}.bridge" (uplink.bridge or null);
            in
            {
              name = bridge;
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
            })
          uplinkNames;
    in
    ensureUniqueEntries "${hostPath}.uplinks[*].bridge" entries;

  buildPortLinkLookup = nodePath: ports: hostUplinkByBridge:
    let
      portNames = sortedNames ports;
      entries =
        builtins.map
          (portName:
            let
              portPath = "${nodePath}.ports.${portName}";
              port = requireAttrs portPath ports.${portName};
              interface = requireAttrs "${portPath}.interface" (port.interface or null);
              linkRef = requireString "${portPath}.link" (port.link or null);
              runtimeIfName = requireString "${portPath}.interface.name" (interface.name or null);
              attach = port.attach or null;

              bridgeName =
                if builtins.isAttrs attach && builtins.isString (attach.bridge or null) && attach.bridge != "" then
                  attach.bridge
                else
                  null;

              hostUplink =
                if bridgeName != null && hasAttr bridgeName hostUplinkByBridge then
                  hostUplinkByBridge.${bridgeName}
                else
                  null;
            in
            {
              name = linkRef;
              value = {
                runtimePort = portName;
                runtimeIfName = runtimeIfName;
                attach = attach;
                hostUplink = hostUplink;
              };
            })
          portNames;
    in
    ensureUniqueEntries "${nodePath}.ports[*].link" entries;
in
builtins.foldl'
  (acc: targetName:
    let
      nodePath = "inventory.realization.nodes.${targetName}";
      node = requireAttrs nodePath realizationNodes.${targetName};
      logicalNode = requireAttrs "${nodePath}.logicalNode" (node.logicalNode or null);
      logical = {
        enterprise = requireString "${nodePath}.logicalNode.enterprise" (logicalNode.enterprise or null);
        site = requireString "${nodePath}.logicalNode.site" (logicalNode.site or null);
        name = requireString "${nodePath}.logicalNode.name" (logicalNode.name or null);
      };
      key = logicalKey logical;
      ports = optionalAttrs (node.ports or null);

      hostName =
        if builtins.isString (node.host or null) && node.host != "" then
          node.host
        else
          null;

      hostUplinkByBridge =
        if hostName != null && hasAttr hostName deploymentHosts then
          buildHostUplinkByBridge "inventory.deployment.hosts.${hostName}" deploymentHosts.${hostName}
        else
          { };

      linkLookup = buildPortLinkLookup nodePath ports hostUplinkByBridge;
    in
    if hasAttr key acc.byLogical then
      throw "runtime realization failure: logical node '${key}' is realized by multiple runtime targets"
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
              linkLookup = linkLookup;
            };
          };
      })
  {
    byLogical = { };
    targetDefs = { };
  }
  (sortedNames realizationNodes)
