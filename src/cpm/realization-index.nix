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
  fabricLinksRoot =
    if builtins.isAttrs (realization.fabricLinks or null) then
      requireAttrs "inventory.realization.fabricLinks" realization.fabricLinks
    else
      { };

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
  fabricLinkLib = import ./EquipmentModule/realization-index/fabric-links.nix {
    inherit helpers failInventory;
  };
  inherit (hostLib) hostIndex;
  inherit (portLib)
    buildSelectorIndex
    normalizeContainerBinding
    normalizePortBinding
    ;
  inherit (fabricLinkLib) normalizeFabricLinks;

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
              normalizePortBinding targetPath targetHostName platform portName ports.${portName})
            (sortedNames ports)
        );

      fabricLinkBindings = normalizeFabricLinks targetName targetPath target fabricLinksRoot;

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
            byServiceInterface = buildSelectorIndex targetPath portDefs "serviceInterface";
            byUplink = buildSelectorIndex targetPath portDefs "uplink";
          };
          fabricLinkBindings = fabricLinkBindings;
          containerBindings = containerBindings;
        };
      };

  targetDefs =
    builtins.listToAttrs (
      builtins.map
        buildTargetDef
        (sortedNames nodesRoot)
    );

  validations = import ./EquipmentModule/realization-index/validations.nix {
    inherit helpers targetDefs;
  };
  inherit (validations)
    validateUniqueFabricLinksPerTarget
    validateUniqueLinkAdapterNamesPerHost
    validateUniqueRuntimeIfNamesPerTarget
    ;

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
builtins.seq validateUniqueLinkAdapterNamesPerHost
  (builtins.seq validateUniqueRuntimeIfNamesPerTarget (builtins.seq validateUniqueFabricLinksPerTarget {
    inherit targetDefs byLogical;
  }))
