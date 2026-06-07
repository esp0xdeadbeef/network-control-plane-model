{ buildFromPaths }:

{ intentPath
, inventoryPath ? null
, ...
}:

{ pkgs, ... }:

let
  clientFixture =
    buildFromPaths {
      inherit pkgs intentPath inventoryPath;
    };
in
{
  _module.args.clientFixture = clientFixture;
  _module.args.renderedHostNetwork = clientFixture.hostNetwork;
}
