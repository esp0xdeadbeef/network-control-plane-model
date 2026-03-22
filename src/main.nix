{ input, inventory ? {} }:

let
  lib = import ../lib/utils.nix;

  normalize = import ./normalize-forwarding-model.nix;
  deriveCPM = import ./build-cpm.nix { inherit lib; };
  mergeInputs = import ./merge-inputs.nix;
  validateInventory = import ./validate-inventory.nix { inherit lib; };

  normalized = normalize input;

  enterprise =
    if builtins.isAttrs (normalized.enterprise or null) then
      normalized.enterprise
    else
      throw "missing required forwardingModel.enterprise attribute set";

  cpm = deriveCPM enterprise;

  merged =
    mergeInputs {
      forwardingModel = normalized;
      inventory = inventory;
    }
    // {
      control_plane_model = cpm;
    };

  inventoryValidation =
    if inventory == {} then
      true
    else
      validateInventory {
        inherit inventory cpm;
      };

in
builtins.seq cpm (
  builtins.seq inventoryValidation merged
)
