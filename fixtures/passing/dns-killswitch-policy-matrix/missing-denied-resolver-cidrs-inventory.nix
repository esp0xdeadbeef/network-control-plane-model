let
  base = import ./inventory.nix;
in
base
  // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services.dns =
          (builtins.removeAttrs
            base.realization.nodes.access-runtime.services.dns
            [ "deniedResolverCidrs" ])
          // {
            killSwitch.blockPublicResolvers = true;
          };
      };
    };
  };
}
