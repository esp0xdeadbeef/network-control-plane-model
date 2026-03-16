{ input, inventory ? {} }:

let
  lib = import ../lib/utils.nix;

  normalize = import ./normalize-forwarding-model.nix;
  deriveCPM = import ./build-cpm.nix { inherit lib; };
  mergeInputs = import ./merge-inputs.nix;

  normalized = normalize input;

  cpm = deriveCPM (normalized.enterprise or {});

in
mergeInputs {
  forwardingModel = normalized;
  inventory = inventory;
}
// {
  control_plane_model = cpm;
}
