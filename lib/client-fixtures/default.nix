{ lib }:

{
  hostModuleFromPaths = import ./host-module-from-paths.nix { inherit lib; };
}
