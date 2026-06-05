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
      deniedResolverCidrs = publicResolverCidrs;
      inherit allowedUpstreamClasses;
    };

  publicResolverCidrs = [
    "1.1.1.1/32"
    "1.0.0.1/32"
    "8.8.8.8/32"
    "8.8.4.4/32"
    "9.9.9.9/32"
    "2606:4700:4700::1111/128"
    "2606:4700:4700::1001/128"
    "2001:4860:4860::8888/128"
    "2001:4860:4860::8844/128"
    "2620:fe::fe/128"
  ];

  withExplicitDeniedResolverCidrs =
    node:
    node
    // {
      services = (node.services or { }) // {
        dns = (node.services.dns or { }) // {
          deniedResolverCidrs = publicResolverCidrs;
        };
      };
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
      access-runtime = (withExplicitDeniedResolverCidrs base.realization.nodes.access-runtime) // {
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

      core-runtime = (withExplicitDeniedResolverCidrs base.realization.nodes.core-runtime) // {
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
          deniedResolverCidrs = publicResolverCidrs;
          allowedUpstreamClasses = [ "explicit-egress-default" ];
        };
      };

      globex-nyc-access-runtime =
        withExplicitDeniedResolverCidrs base.realization.nodes.globex-nyc-access-runtime;

      globex-lon-access-runtime =
        withExplicitDeniedResolverCidrs base.realization.nodes.globex-lon-access-runtime;
    };
  };
}
