{ lib }:

{ inventory, cpm ? null, forwardingModel }:

let
  helpers = import ./cpm/cpm-contract-support.nix { inherit lib; };

  realizationIndex =
    import ./cpm/realization-index.nix {
      inherit helpers inventory;
    };
in
import ./cpm/ControlModule/inventory-validation.nix
{
  inherit helpers;
}
{
  inherit inventory forwardingModel realizationIndex;
}
