{ lib }:
args@{ forwardingModel, ... }:
let
  helpers =
    import ./cpm/cpm-contract-support.nix { inherit lib; };

  passthroughArgs =
    builtins.removeAttrs args [ "forwardingModel" ];

  validatorArgs = {
    helpers = helpers;
  };

  cpmArgs =
    passthroughArgs
    // {
      helpers = helpers;
      lib = lib;
      forwardingModel = forwardingModel;
    };

  _validated =
    import ./cpm/validate-forwarding-model.nix validatorArgs forwardingModel;

  cpm =
    import ./cpm cpmArgs;
in
builtins.seq
  _validated
  cpm
