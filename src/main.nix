{ input, inventory ? {} }:

let
  cleaned = builtins.removeAttrs input [ "endpointInventory" ];
in
cleaned // {
  endpointInventory = inventory;
}
