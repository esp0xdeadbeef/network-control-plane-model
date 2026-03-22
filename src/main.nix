{ input, inventory ? {} }:

let
  lib = import ../lib/utils.nix;

  normalize = import ./normalize-forwarding-model.nix;
  deriveCPM = import ./build-cpm.nix { inherit lib; };
  mergeInputs = import ./merge-inputs.nix;

  normalized = normalize input;

  enterprise =
    if builtins.isAttrs (normalized.enterprise or null) then
      normalized.enterprise
    else
      throw "missing required forwardingModel.enterprise attribute set";

  cpm = deriveCPM enterprise;

in
mergeInputs {
  forwardingModel = normalized;
  inventory = inventory;
}
// {
  control_plane_model = cpm;
}
