let
  base = import ../default-egress-reachability/inventory.nix;

  dnsFor =
    allowedUpstreamClasses:
    {
      implementation = "unbound";
      listen = [
        "10.20.0.1"
        "fd00:20::1"
      ];
      allowFrom = [
        "10.20.0.0/24"
        "fd00:20::/64"
      ];
      inherit allowedUpstreamClasses;
    };

  accessPolicyMatrix = [
    {
      name = "local-only";
      allowedUpstreamClasses = [ "local-access" ];
    }
    {
      name = "overlay-allowed";
      allowedUpstreamClasses = [
        "local-access"
        "overlay-core"
      ];
    }
    {
      name = "service-dns-allowed";
      allowedUpstreamClasses = [
        "local-access"
        "service-dns"
      ];
    }
    {
      name = "explicit-egress-dns";
      allowedUpstreamClasses = [
        "local-access"
        "explicit-egress-default"
      ];
    }
    {
      name = "denied";
      allowedUpstreamClasses = [ "local-access" ];
    }
  ];
in
base
// {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services.dns =
          dnsFor [
            "local-access"
            "overlay-core"
            "service-dns"
            "explicit-egress-default"
          ]
          // {
            policyMatrix = accessPolicyMatrix;
            routeContracts = [
              {
                destination = "0.0.0.0/0";
                class = "explicit-egress-default";
                explicitlyAllowed = true;
              }
              {
                destination = "::/0";
                class = "explicit-egress-default";
                explicitlyAllowed = true;
              }
            ];
          };
      };

      core-runtime = base.realization.nodes.core-runtime // {
        services.dns = {
          implementation = "unbound";
          listen = [
            "192.0.2.2"
            "2001:db8:1::2"
          ];
          allowFrom = [
            "10.20.0.0/24"
            "fd00:20::/64"
          ];
          allowedUpstreamClasses = [ "explicit-egress-default" ];
        };
      };
    };
  };
}
