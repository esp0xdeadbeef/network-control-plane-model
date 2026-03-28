{ input, inventory ? {}, lib }:

let
  localLib = import ../lib/utils.nix;
  effectiveLib = lib // localLib;

  deriveCPM = import ./build-cpm.nix { lib = effectiveLib; };

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
