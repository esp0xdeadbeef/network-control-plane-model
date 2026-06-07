{ buildFromPaths }:

{ intentPath
, inventoryPath ? null
, ...
}:

{ pkgs, ... }:
{
  _module.args.clientFixture =
    buildFromPaths {
      inherit pkgs intentPath inventoryPath;
    };
}
