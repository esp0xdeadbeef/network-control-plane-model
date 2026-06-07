{ lib }:

{ buildFromPaths }:

{
  hostModuleFromPaths =
    import ./host-module-from-paths.nix {
      inherit buildFromPaths;
    };
}
