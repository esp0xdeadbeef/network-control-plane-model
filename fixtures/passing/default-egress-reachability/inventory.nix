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
        advertisements = {
          dhcp4 = {
            tenant0 = {
              enabled = true;
              id = "tenant-a";
              subnet = "10.20.0.0/24";
              pool = {
                start = "10.20.0.100";
                end = "10.20.0.200";
              };
              router = "10.20.0.1";
              dnsServers = [ "10.20.0.1" ];
              domain = "lan.";
            };
          };
          ipv6Ra = {
            tenant0 = {
              enabled = true;
              prefixes = [ "fd00:20::/64" ];
              rdnss = [ "fd00:20::1" ];
              dnssl = [ "lan." ];
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
            external = true;
            uplink = "wan";
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

      globex-nyc-access-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "globex";
          site = "nyc";
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
        advertisements = {
          dhcp4 = {
            tenant0 = {
              enabled = true;
              id = "tenant-b";
              subnet = "10.30.0.0/24";
              pool = {
                start = "10.30.0.100";
                end = "10.30.0.200";
              };
              router = "10.30.0.1";
              dnsServers = [ "10.30.0.1" ];
              domain = "lan.";
            };
          };
          ipv6Ra = {
            tenant0 = {
              enabled = true;
              prefixes = [ "fd00:30::/64" ];
              rdnss = [ "fd00:30::1" ];
              dnssl = [ "lan." ];
            };
          };
        };
      };

      globex-nyc-policy-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "globex";
          site = "nyc";
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
              name = "ens3";
            };
          };

          p2p-upstream = {
            link = "link-upstream-policy";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens4";
            };
          };
        };
      };

      globex-nyc-upstream-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "globex";
          site = "nyc";
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
              name = "ens3";
            };
          };

          p2p-policy = {
            link = "link-upstream-policy";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens4";
            };
          };
        };
      };

      globex-nyc-core-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "globex";
          site = "nyc";
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
              name = "ens3";
            };
          };

          uplink0 = {
            external = true;
            uplink = "wan";
            attach = {
              kind = "bridge";
              bridge = "br-wan";
            };
            interface = {
              name = "ens4";
            };
          };
        };
      };

      globex-lon-access-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "globex";
          site = "lon";
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
        advertisements = {
          dhcp4 = {
            tenant0 = {
              enabled = true;
              id = "tenant-c";
              subnet = "10.40.0.0/24";
              pool = {
                start = "10.40.0.100";
                end = "10.40.0.200";
              };
              router = "10.40.0.1";
              dnsServers = [ "10.40.0.1" ];
              domain = "lan.";
            };
          };
          ipv6Ra = {
            tenant0 = {
              enabled = true;
              prefixes = [ "fd00:40::/64" ];
              rdnss = [ "fd00:40::1" ];
              dnssl = [ "lan." ];
            };
          };
        };
      };

      globex-lon-policy-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "globex";
          site = "lon";
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
              name = "ens3";
            };
          };

          p2p-upstream = {
            link = "link-upstream-policy";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens4";
            };
          };
        };
      };

      globex-lon-upstream-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "globex";
          site = "lon";
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
              name = "ens3";
            };
          };

          p2p-policy = {
            link = "link-upstream-policy";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens4";
            };
          };
        };
      };

      globex-lon-core-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "globex";
          site = "lon";
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
              name = "ens3";
            };
          };
        };
      };
    };
  };
}
