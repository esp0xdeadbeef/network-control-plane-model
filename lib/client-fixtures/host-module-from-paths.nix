{ buildFromPaths }:

{ pkgs
, intentPath
, inventoryPath ? null
, ...
}@args:

let
  clientFixture = buildFromPaths args;

  controlPlaneModel =
    clientFixture.control_plane_model or clientFixture;

  renderedHostNetwork =
    clientFixture.hostNetwork
      or controlPlaneModel.hostNetwork
      or controlPlaneModel.renderedHostNetwork
      or (throw "network-control-plane-model client fixture does not contain hostNetwork");
in
{
  _module.args.clientFixture = clientFixture;
  _module.args.controlPlaneModel = controlPlaneModel;
  _module.args.renderedHostNetwork = renderedHostNetwork;
}
