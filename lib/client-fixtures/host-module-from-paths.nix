{ buildFromPaths }:

args:

let
  clientFixture =
    buildFromPaths args;

  controlPlaneModel =
    clientFixture.control_plane_model or clientFixture;

  renderedHostNetwork =
    clientFixture.renderedHostNetwork
      or clientFixture.hostNetwork
      or controlPlaneModel.renderedHostNetwork
      or controlPlaneModel.hostNetwork;
in
{
  _module.args.clientFixture = clientFixture;
  _module.args.controlPlaneModel = controlPlaneModel;
  _module.args.renderedHostNetwork = renderedHostNetwork;
}
