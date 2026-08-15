let
  base = import ./inventory.nix;
in
base
  // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      core-runtime = base.realization.nodes.core-runtime // {
        services.dns = base.realization.nodes.core-runtime.services.dns // {
          forwarders = [ "192.0.2.3" ];
        };
      };
    };
  };
}
