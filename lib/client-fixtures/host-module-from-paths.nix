{ buildFromPaths }:

args:

let
  clientFixture =
    buildFromPaths args;

  controlPlaneModel =
    clientFixture.control_plane_model or clientFixture;

  renderedHostNetwork =
    if clientFixture ? renderedHostNetwork then
      clientFixture.renderedHostNetwork
    else if clientFixture ? hostNetwork then
      clientFixture.hostNetwork
    else if controlPlaneModel ? renderedHostNetwork then
      controlPlaneModel.renderedHostNetwork
    else
      { };
in
{
  _module.args.clientFixture = clientFixture;
  _module.args.controlPlaneModel = controlPlaneModel;
  _module.args.renderedHostNetwork = renderedHostNetwork;
}
