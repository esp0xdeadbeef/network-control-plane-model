{ buildFromPaths }:

args:

let
  pkgs =
    args.pkgs or null;

  system =
    args.system
      or (if pkgs == null then null else pkgs.system)
      or (throw "network-control-plane-model client fixture requires either pkgs or system");

  clientFixture =
    buildFromPaths (args // { inherit system; });

  controlPlaneModel =
    clientFixture.control_plane_model or clientFixture;

  renderedHostNetwork =
    clientFixture.hostNetwork
      or clientFixture.renderedHostNetwork
      or controlPlaneModel.hostNetwork
      or controlPlaneModel.renderedHostNetwork
      or (throw "network-control-plane-model client fixture does not contain hostNetwork");
in
{
  _module.args.clientFixture = clientFixture;
  _module.args.controlPlaneModel = controlPlaneModel;
  _module.args.renderedHostNetwork = renderedHostNetwork;
}
