{ helpers }:

{ forwardingModel, inventory ? { }, realizationIndex }:

let
  inherit (helpers) forceAll hasAttr sortedNames;

  failInventory = path: message:
    throw "inventory lint error: ${path}: ${message}";

  sitesByKey = import ./inventory-validation/site-contracts.nix { inherit helpers; } {
    inherit forwardingModel;
  };

  validatePortBinding = import ./inventory-validation/port-binding.nix {
    inherit helpers failInventory;
  };

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
          validatePortBinding {
            inherit targetDef siteContract nodeContract portName;
          })
        (sortedNames targetDef.portBindings.portDefs)
    );

  validateRuntimeTargetCoverage = import ./inventory-validation/runtime-target-coverage.nix
    {
      inherit helpers;
    }
    {
      inherit sitesByKey realizationIndex;
    };
in
builtins.seq
  (forceAll (
    builtins.map
      validateRealizedTarget
      (sortedNames realizationIndex.targetDefs)
  ))
  validateRuntimeTargetCoverage
