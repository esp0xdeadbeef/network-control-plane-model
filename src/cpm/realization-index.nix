{ helpers, inventory }:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    optionalAttrs
    requireAttrs
    requireString
    sortedNames
    ;

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  inventoryRoot = optionalAttrs inventory;
  deployment = requireAttrs "inventory.deployment" (inventoryRoot.deployment or { });
  hostsRoot = requireAttrs "inventory.deployment.hosts" (deployment.hosts or { });
  realization = requireAttrs "inventory.realization" (inventoryRoot.realization or { });
  nodesRoot = requireAttrs "inventory.realization.nodes" (realization.nodes or { });

  routeLib = import ./EquipmentModule/realization-index/routes.nix {
    inherit helpers failInventory;
  };
  hostLib = import ./EquipmentModule/realization-index/hosts.nix {
    inherit helpers failInventory hostsRoot;
  };
  portLib = import ./EquipmentModule/realization-index/ports.nix {
    inherit helpers failInventory;
    inherit (hostLib) hostIndex;
    inherit (routeLib) requireRoutes;
  };
  inherit (hostLib) hostIndex;
  inherit (portLib)
    buildSelectorIndex
    normalizeContainerBinding
    normalizePortBinding
    ;

  buildTargetDef = targetName:
    let
      targetPath = "inventory.realization.nodes.${targetName}";
      target = requireAttrs targetPath nodesRoot.${targetName};

      targetHostName =
        requireString "${targetPath}.host" (target.host or null);

      _hostExists =
        if hasAttr targetHostName hostIndex then
          true
        else
          failInventory "${targetPath}.host" "references unknown deployment host '${targetHostName}'";

      platform =
        requireString "${targetPath}.platform" (target.platform or null);

      logicalNode =
        requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);

      logical = {
        enterprise =
          requireString "${targetPath}.logicalNode.enterprise" (logicalNode.enterprise or null);
        site =
          requireString "${targetPath}.logicalNode.site" (logicalNode.site or null);
        name =
          requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      };

      ports =
        if builtins.isAttrs (target.ports or null) then
          requireAttrs "${targetPath}.ports" target.ports
        else
          { };

      portDefs =
        builtins.listToAttrs (
          builtins.map
            (portName:
              normalizePortBinding targetPath targetHostName portName ports.${portName})
            (sortedNames ports)
        );

      containers =
        if builtins.isAttrs (target.containers or null) then
          requireAttrs "${targetPath}.containers" target.containers
        else
          { };

      containerBindings =
        builtins.listToAttrs (
          builtins.map
            (containerName:
              normalizeContainerBinding targetPath containerName containers.${containerName})
            (sortedNames containers)
        );
    in
    builtins.seq
      _hostExists
      {
        name = targetName;
        value = {
          node = target;
          nodePath = targetPath;
          host = targetHostName;
          platform = platform;
          logical = logical;
          portBindings = {
            portDefs = portDefs;
            byLink = buildSelectorIndex targetPath portDefs "link";
            byLogicalInterface = buildSelectorIndex targetPath portDefs "logicalInterface";
            byUplink = buildSelectorIndex targetPath portDefs "uplink";
          };
          containerBindings = containerBindings;
        };
      };

  targetDefs =
    builtins.listToAttrs (
      builtins.map
        buildTargetDef
        (sortedNames nodesRoot)
    );

  _validateUniqueLinkAdapterNamesPerHost =
    ensureUniqueEntries
      "inventory.realization.nodes.*.ports.*.adapterName (must be unique per deployment host for link selectors)"
      (
        builtins.concatLists (
          builtins.map
            (targetName:
              let
                targetDef = targetDefs.${targetName};
                hostName = targetDef.host;
                targetPath = targetDef.nodePath;
              in
              builtins.concatLists (
                builtins.map
                  (portName:
                    let
                      portDef = targetDef.portBindings.portDefs.${portName};
                    in
                    if portDef.selector.kind == "link" then
                      [
                        {
                          name = "${hostName}|${portDef.adapterName}";
                          value = {
                            host = hostName;
                            target = targetName;
                            port = portName;
                            path = "${targetPath}.ports.${portName}.adapterName";
                          };
                        }
                      ]
                    else
                      [ ])
                  (sortedNames targetDef.portBindings.portDefs)
              ))
            (sortedNames targetDefs)
        )
      );

  byLogical =
    ensureUniqueEntries
      "inventory.realization.nodes.*.logicalNode"
      (
        builtins.map
          (targetName:
            let
              logical = targetDefs.${targetName}.logical;
            in
            {
              name = "${logical.enterprise}|${logical.site}|${logical.name}";
              value = targetName;
            })
          (sortedNames targetDefs)
      );
in
builtins.seq _validateUniqueLinkAdapterNamesPerHost {
  inherit targetDefs byLogical;
}
