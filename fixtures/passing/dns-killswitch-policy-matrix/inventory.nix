let
  base = import ../default-egress-reachability/inventory.nix;

  registeredUpstream = {
    sourceFile = "/run/mullvad/dns";
    family = "any";
  };

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
      strictEgress = true;
      inherit allowedUpstreamClasses;
    };

  withStrictEgress =
    node:
    node
    // {
      services = (node.services or { }) // {
        dns = (node.services.dns or { }) // {
          strictEgress = true;
          registeredUpstreams = [ registeredUpstream ];
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
      access-runtime = (withStrictEgress base.realization.nodes.access-runtime) // {
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

      core-runtime = (withStrictEgress base.realization.nodes.core-runtime) // {
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
          strictEgress = true;
          registeredUpstreams = [ registeredUpstream ];
          allowedUpstreamClasses = [ "explicit-egress-default" ];
        };
      };

      globex-nyc-access-runtime =
        withStrictEgress base.realization.nodes.globex-nyc-access-runtime;

      globex-lon-access-runtime =
        withStrictEgress base.realization.nodes.globex-lon-access-runtime;
    };
  };
}
