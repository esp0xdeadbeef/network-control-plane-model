{ lib }:
args@{ forwardingModel, validateForwardingModel ? true, validateRuntimeModel ? false, ... }:
let
  helpers =
    import ./cpm/cpm-contract-support.nix { inherit lib; };

  passthroughArgs =
    builtins.removeAttrs args [ "forwardingModel" "validateForwardingModel" "validateRuntimeModel" ];

  validatorArgs = {
    helpers = helpers;
  };

  cpmArgs =
    passthroughArgs
    // {
      helpers = helpers;
      lib = lib;
      forwardingModel = forwardingModel;
      inherit validateRuntimeModel;
    };

  _validated =
    if validateForwardingModel then
      import ./cpm/validate-forwarding-model.nix validatorArgs forwardingModel
    else
      true;

  cpm =
    import ./cpm cpmArgs;
in
builtins.seq
  _validated
  cpm
