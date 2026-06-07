{ buildFromPaths }:

args:

let
  lib =
    args.lib or null;

  mkDefault =
    value:
    if lib == null then
      value
    else
      lib.mkDefault value;

  fixtureArgs =
    builtins.removeAttrs args [
      "config"
      "lib"
      "options"
    ];

  clientFixture =
    buildFromPaths fixtureArgs;

  controlPlaneModel =
    clientFixture.control_plane_model or clientFixture;

  renderedHostNetwork =
    if clientFixture ? renderedHostNetwork then
      clientFixture.renderedHostNetwork
    else if clientFixture ? hostNetwork then
      clientFixture.hostNetwork
    else if controlPlaneModel ? renderedHostNetwork then
      controlPlaneModel.renderedHostNetwork
    else if controlPlaneModel ? hostNetwork then
      controlPlaneModel.hostNetwork
    else
      { };
in
{
  _module.args.clientFixture = mkDefault clientFixture;
  _module.args.controlPlaneModel = mkDefault controlPlaneModel;
  _module.args.renderedHostNetwork = mkDefault renderedHostNetwork;
}
