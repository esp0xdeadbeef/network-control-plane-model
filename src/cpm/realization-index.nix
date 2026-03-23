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

  buildPortLinkLookup = nodePath: ports:
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
            in
            {
              name = linkRef;
              value = {
                runtimePort = portName;
                runtimeIfName = runtimeIfName;
                attach = port.attach or null;
              };
            })
          portNames;
    in
    ensureUniqueEntries "${nodePath}.ports[*].link" entries;

  inventoryRoot = optionalAttrs inventory;
  realizationRoot = optionalAttrs (inventoryRoot.realization or null);
  realizationNodes = optionalAttrs (realizationRoot.nodes or null);
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
      linkLookup = buildPortLinkLookup nodePath ports;
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
