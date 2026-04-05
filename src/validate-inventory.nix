{ lib }:

{ inventory, cpm, forwardingModel }:

let
  helpers = import ./cpm/cpm-contract-support.nix { inherit lib; };

  forwardingSiteIndex =
    import ./inventory/forwarding-site-index.nix {
      inherit helpers;
    } forwardingModel;

  realizationIndex =
    import ./cpm/realization-index.nix {
      inherit helpers inventory;
    };

  inherit (helpers)
    forceAll
    hasAttr
    requireAttrs
    requireString
    sortedNames;

  failInventory = path: message:
    throw "inventory lint error: ${path}: ${message}";

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
        if hasAttr siteKey forwardingSiteIndex.sitesByKey then
          forwardingSiteIndex.sitesByKey.${siteKey}
        else
          failInventory "${targetDef.nodePath}.logicalNode" "references unknown forwarding-model site '${logical.enterprise}.${logical.site}'";

      nodeContract =
        if hasAttr logical.name siteContract.nodes then
          siteContract.nodes.${logical.name}
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
    let
      data = requireAttrs "control_plane_model.data" (cpm.data or null);
    in
    builtins.concatLists (
      builtins.map
        (enterpriseName:
          let
            sites = requireAttrs "control_plane_model.data.${enterpriseName}" data.${enterpriseName};
          in
          builtins.concatLists (
            builtins.map
              (siteName:
                let
                  sitePath = "control_plane_model.data.${enterpriseName}.${siteName}";
                  site = requireAttrs sitePath sites.${siteName};
                  runtimeTargets = requireAttrs "${sitePath}.runtimeTargets" (site.runtimeTargets or null);
                in
                builtins.concatLists (
                  builtins.map
                    (targetName:
                      let
                        targetPath = "${sitePath}.runtimeTargets.${targetName}";
                        target = requireAttrs targetPath runtimeTargets.${targetName};
                        placement = requireAttrs "${targetPath}.placement" (target.placement or null);
                        logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
                        logical = {
                          enterprise = requireString "${targetPath}.logicalNode.enterprise" (logicalNode.enterprise or null);
                          site = requireString "${targetPath}.logicalNode.site" (logicalNode.site or null);
                          name = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
                        };
                        placementKind = placement.kind or null;
                      in
                      if placementKind == "inventory-realization" then
                        [ ]
                      else
                        [
                          {
                            path = targetPath;
                            runtimeTarget = targetName;
                            actualPlacementKind = placementKind;
                            expectedPlacementKind = "inventory-realization";
                            logicalNode = logical;
                          }
                        ])
                    (sortedNames runtimeTargets)
                ))
              (sortedNames sites)
          ))
        (sortedNames data)
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
