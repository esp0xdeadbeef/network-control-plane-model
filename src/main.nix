# ./src/main.nix
{ input
, inventory ? { }
, lib ? { }
, validateForwardingModel ? true
, validateRuntimeModel ? false
,
}:

let
  localLib = import ../lib/utils.nix;
  effectiveLib = lib // localLib;

  deriveCPM = import ./build-cpm.nix { lib = effectiveLib; };

  cpm =
    builtins.addErrorContext
      "while building network-control-plane-model from the explicit network-forwarding-model input"
      (
        deriveCPM {
          forwardingModel = input;
          inherit inventory validateForwardingModel validateRuntimeModel;
        }
      );

  merged = {
    control_plane_model = cpm;
  };
in
builtins.seq cpm merged
