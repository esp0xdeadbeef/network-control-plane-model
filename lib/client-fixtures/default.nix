{ lib }:

{ buildFromPaths }:

{
  inherit buildFromPaths;

  hostModuleFromPaths =
    import ./host-module-from-paths.nix {
      inherit buildFromPaths;
    };
}
