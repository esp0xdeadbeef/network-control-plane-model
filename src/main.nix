# ./src/main.nix
{ input, inventory ? {}, lib }:

let
  localLib = import ../lib/utils.nix;
  effectiveLib = lib // localLib;

  deriveCPM = import ./build-cpm.nix { lib = effectiveLib; };

  forwardingModelDump = builtins.toJSON input;

  cpm =
    builtins.addErrorContext
      ''
        network-forwarding-model:
        ${forwardingModelDump}
      ''
      (
        deriveCPM {
          forwardingModel = input;
          inherit inventory;
        }
      );

  merged = {
    control_plane_model = cpm;
  };
in
builtins.seq cpm merged
