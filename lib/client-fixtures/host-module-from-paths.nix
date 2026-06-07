{ lib }:

{ intentPath
, inventoryPath
, sopsPath
, fixture
}:

let
  output = import ./build-from-paths.nix { inherit lib; } {
    inherit intentPath inventoryPath sopsPath fixture;
  };
in
{
  imports = [
    sopsPath
  ];

  inherit (output.config)
    system
    environment
    networking
    services
    systemd
    containers
    _module;
}
