{ input, inventory ? {} }:

let
  lib = import ../lib/utils.nix;

  normalize = import ./normalize-forwarding-model.nix;
  deriveCPM = import ./build-cpm.nix { inherit lib; };
  mergeInputs = import ./merge-inputs.nix;
  validateInventory = import ./validate-inventory.nix { inherit lib; };

  normalized = normalize input;

  embeddedInventory =
    if builtins.isAttrs (input.endpointInventory or null) then
      input.endpointInventory
    else
      { };

  effectiveInventory =
    if inventory != {} then
      inventory
    else
      embeddedInventory;

  enterprise =
    if builtins.isAttrs (normalized.enterprise or null) then
      normalized.enterprise
    else
      throw "missing required forwardingModel.enterprise attribute set";

  cpm =
    deriveCPM {
      inherit enterprise;
      inventory = effectiveInventory;
    };

  merged =
    mergeInputs {
      forwardingModel = normalized;
      inventory = effectiveInventory;
    }
    // {
      control_plane_model = cpm;
    };

  inventoryValidation =
    if effectiveInventory == {} then
      true
    else
      validateInventory {
        inventory = effectiveInventory;
        inherit cpm;
      };

in
builtins.seq cpm (
  builtins.seq inventoryValidation merged
)
