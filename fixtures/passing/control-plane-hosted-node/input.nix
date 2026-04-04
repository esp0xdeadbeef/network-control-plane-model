{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 7;
    };
  };

  enterprise = {
    esp0xdeadbeef = {
      site = {
        site-a = {
          siteId = "site-a";
          siteName = "esp0xdeadbeef.site-a";

          attachments = [ ];

          policyNodeName = "s-router-policy";
          upstreamSelectorNodeName = "s-router-edge";
          coreNodeNames = [ ];
          uplinkCoreNames = [ ];
          uplinkNames = [ ];

          domains = {
            tenants = [ ];
            externals = [ ];
          };

          tenantPrefixOwners = { };

          links = {
            transit-policy-edge = {
              id = "adj::esp0xdeadbeef.site-a::transit-policy-edge";
              kind = "p2p";
              members = [ "s-router-policy" "s-router-edge" ];
              endpoints = {
                s-router-policy = {
                  node = "s-router-policy";
                  interface = "eth-transit";
                  addr4 = "169.254.100.1/31";
                  addr6 = "fd00:100::1/127";
                };
                s-router-edge = {
                  node = "s-router-edge";
                  interface = "eth-transit";
                  addr4 = "169.254.100.0/31";
                  addr6 = "fd00:100::0/127";
                };
              };
            };
          };

          transit = {
            adjacencies = [
              {
                id = "adj::esp0xdeadbeef.site-a::transit-policy-edge";
                kind = "p2p";
                link = "transit-policy-edge";
                endpoints = [
                  {
                    unit = "s-router-policy";
                    local = {
                      ipv4 = "169.254.100.1";
                      ipv6 = "fd00:100::1";
                    };
                  }
                  {
                    unit = "s-router-edge";
                    local = {
                      ipv4 = "169.254.100.0";
                      ipv6 = "fd00:100::0";
                    };
                  }
                ];
              }
            ];

            ordering = [
              "adj::esp0xdeadbeef.site-a::transit-policy-edge"
            ];
          };

          communicationContract = {
            interfaceTags = { };
            allowedRelations = [ ];
          };

          nodes = {
            s-router-policy = {
              role = "policy";
              loopback = {
                ipv4 = "10.255.10.1/32";
                ipv6 = "fd00:ff:10::1/128";
              };
              interfaces = {
                p2p0 = {
                  interface = "eth-transit";
                  kind = "p2p";
                  link = "transit-policy-edge";
                  addr4 = "169.254.100.1/31";
                  addr6 = "fd00:100::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            s-router-edge = {
              role = "upstream-selector";
              loopback = {
                ipv4 = "10.255.10.2/32";
                ipv6 = "fd00:ff:10::2/128";
              };
              interfaces = {
                p2p0 = {
                  interface = "eth-transit";
                  kind = "p2p";
                  link = "transit-policy-edge";
                  addr4 = "169.254.100.0/31";
                  addr6 = "fd00:100::0/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
