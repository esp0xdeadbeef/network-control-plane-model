# ./src/main.nix
{ input
, inventory ? { }
, lib ? { }
, includeForwardingModelErrorContext ? false
, validateForwardingModel ? true
, validateRuntimeModel ? false
,
}:

let
  localLib = import ../lib/utils.nix;
  effectiveLib = lib // localLib;

  deriveCPM = import ./build-cpm.nix { lib = effectiveLib; };

  rawCpm =
    deriveCPM {
      forwardingModel = input;
      inherit inventory validateForwardingModel validateRuntimeModel;
    };

  cpm =
    if includeForwardingModelErrorContext then
      let
        forwardingModelDump = builtins.toJSON input;
      in
    builtins.addErrorContext
      ''
        network-forwarding-model:
        ${forwardingModelDump}
      ''
      rawCpm
    else
      rawCpm;

  merged = {
    control_plane_model = cpm;
  };
in
builtins.seq cpm merged
