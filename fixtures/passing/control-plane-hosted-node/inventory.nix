{
  deployment = {
    hosts = {
      hypervisor-a = {
        uplinks = {
          uplink0 = {
            parent = "eno1";
            bridge = "br-uplink-a";
          };
        };

        transitBridges = {
          br-transit-a = {
            name = "br-transit-a";
            vlan = 100;
            parentUplink = "uplink0";
          };
        };
      };

      hypervisor-b = {
        uplinks = {
          uplink0 = {
            parent = "eno1";
            bridge = "br-uplink-b";
          };
        };

        transitBridges = {
          br-transit-b = {
            name = "br-transit-b";
            vlan = 100;
            parentUplink = "uplink0";
          };
        };
      };
    };
  };

  realization = {
    nodes = {
      s-router-policy = {
        host = "hypervisor-a";
        platform = "linux";

        logicalNode = {
          enterprise = "esp0xdeadbeef";
          site = "site-a";
          name = "s-router-policy";
        };

        ports = {
          wan0 = {
            link = "transit-policy-edge";
            attach = {
              kind = "bridge";
              bridge = "br-transit-a";
            };
            interface = {
              name = "ens3";
            };
          };
        };
      };

      s-router-edge = {
        host = "hypervisor-b";
        platform = "linux";

        logicalNode = {
          enterprise = "esp0xdeadbeef";
          site = "site-a";
          name = "s-router-edge";
        };

        ports = {
          wan0 = {
            link = "transit-policy-edge";
            attach = {
              kind = "bridge";
              bridge = "br-transit-b";
            };
            interface = {
              name = "ens4";
            };
          };
        };
      };
    };
  };
}
