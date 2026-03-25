{ input, inventory ? {} }:

let
  lib = import ../lib/utils.nix;

  deriveCPM = import ./build-cpm.nix { inherit lib; };

  cpm =
    deriveCPM {
      forwardingModel = input;
      inherit inventory;
    };

  inventoryValidation = true;

  merged = {
    control_plane_model = cpm;
  };

in
builtins.seq cpm (
  builtins.seq inventoryValidation merged
)
