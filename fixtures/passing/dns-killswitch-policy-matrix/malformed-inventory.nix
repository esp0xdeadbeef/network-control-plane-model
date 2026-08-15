let
  base = import ./inventory.nix;
in
base
  // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services.dns = base.realization.nodes.access-runtime.services.dns // {
          registeredUpstreams = [
            {
              sourceFile = "/run/mullvad/dns";
              family = "bogus";
            }
          ];
        };
      };
    };
  };
}
