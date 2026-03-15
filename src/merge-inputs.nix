# ./src/merge-inputs.nix
{ forwardingModel, inventory }:

forwardingModel // {
  endpointInventory = inventory;
}
