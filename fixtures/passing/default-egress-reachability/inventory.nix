{
  deployment = {
    hosts = {
      hypervisor-a = {
        uplinks = {
          uplink0 = {
            parent = "eno1";
            bridge = "br-wan";
            ipv4 = {
              method = "dhcp";
            };
            ipv6 = {
              method = "dhcp";
            };
          };
        };

        transitBridges = {
          br-transit = {
            name = "br-transit";
            vlan = 100;
            parentUplink = "uplink0";
          };
        };
      };
    };
  };

  realization = {
    nodes = {
      access-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "acme";
          site = "ams";
          name = "access-1";
        };
        ports = {
          p2p0 = {
            link = "link-policy-access";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens3";
            };
          };
        };
      };

      policy-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "acme";
          site = "ams";
          name = "policy-1";
        };
        ports = {
          p2p-access = {
            link = "link-policy-access";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens4";
            };
          };

          p2p-upstream = {
            link = "link-upstream-policy";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens5";
            };
          };
        };
      };

      upstream-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "acme";
          site = "ams";
          name = "upstream-1";
        };
        ports = {
          p2p-core = {
            link = "link-core-upstream";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens6";
            };
          };

          p2p-policy = {
            link = "link-upstream-policy";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens7";
            };
          };
        };
      };

      core-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "acme";
          site = "ams";
          name = "core-1";
        };
        ports = {
          p2p-upstream = {
            link = "link-core-upstream";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens8";
            };
          };

          uplink0 = {
            link = "wan-core";
            attach = {
              kind = "bridge";
              bridge = "br-wan";
            };
            interface = {
              name = "ens9";
            };
          };
        };
      };
    };
  };
}
