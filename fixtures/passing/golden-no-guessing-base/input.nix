{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 7;
    };
  };

  enterprise = {
    acme = {
      site = {
        ams = {
          siteId = "ams";
          siteName = "acme.ams";

          attachments = [
            {
              kind = "tenant";
              name = "tenant-a";
              unit = "access-1";
            }
          ];

          policyNodeName = "policy-1";
          upstreamSelectorNodeName = "upstream-1";
          coreNodeNames = [ "core-1" ];
          uplinkCoreNames = [ "core-1" ];
          uplinkNames = [ "wan" ];

          domains = {
            tenants = [
              {
                name = "tenant-a";
                ipv4 = "10.20.0.0/24";
                ipv6 = "fd00:20::/64";
              }
            ];
            externals = [
              {
                name = "wan";
              }
            ];
          };

          tenantPrefixOwners = {
            "4|10.20.0.0/24" = {
              family = 4;
              dst = "10.20.0.0/24";
              netName = "tenant-a";
              owner = "access-1";
            };
          };

          links = {
            link-policy-access = {
              id = "adj::acme.ams::policy-access";
              kind = "p2p";
              members = [ "policy-1" "access-1" ];
              endpoints = {
                policy-1 = {
                  node = "policy-1";
                  interface = "eth-access";
                  addr4 = "169.254.10.1/31";
                  addr6 = "fd00:10::1/127";
                };
                access-1 = {
                  node = "access-1";
                  interface = "eth-policy";
                  addr4 = "169.254.10.0/31";
                  addr6 = "fd00:10::0/127";
                };
              };
            };

            link-upstream-policy = {
              id = "adj::acme.ams::upstream-policy";
              kind = "p2p";
              members = [ "upstream-1" "policy-1" ];
              endpoints = {
                upstream-1 = {
                  node = "upstream-1";
                  interface = "eth-policy";
                  addr4 = "169.254.11.0/31";
                  addr6 = "fd00:11::0/127";
                };
                policy-1 = {
                  node = "policy-1";
                  interface = "eth-upstream";
                  addr4 = "169.254.11.1/31";
                  addr6 = "fd00:11::1/127";
                };
              };
            };

            link-core-upstream = {
              id = "adj::acme.ams::core-upstream";
              kind = "p2p";
              members = [ "core-1" "upstream-1" ];
              endpoints = {
                core-1 = {
                  node = "core-1";
                  interface = "eth-upstream";
                  addr4 = "169.254.12.0/31";
                  addr6 = "fd00:12::0/127";
                };
                upstream-1 = {
                  node = "upstream-1";
                  interface = "eth-core";
                  addr4 = "169.254.12.1/31";
                  addr6 = "fd00:12::1/127";
                };
              };
            };

            wan-core = {
              id = "link::acme.ams::wan-core";
              kind = "wan";
              members = [ "core-1" ];
              endpoints = {
                core-1 = {
                  node = "core-1";
                  interface = "wan0";
                  addr4 = "192.0.2.2/31";
                  addr6 = "2001:db8:1::2/127";
                };
              };
            };
          };

          transit = {
            adjacencies = [
              {
                id = "adj::acme.ams::core-upstream";
                kind = "p2p";
                link = "link-core-upstream";
                endpoints = [
                  {
                    unit = "core-1";
                    local = {
                      ipv4 = "169.254.12.0";
                      ipv6 = "fd00:12::0";
                    };
                  }
                  {
                    unit = "upstream-1";
                    local = {
                      ipv4 = "169.254.12.1";
                      ipv6 = "fd00:12::1";
                    };
                  }
                ];
              }
              {
                id = "adj::acme.ams::upstream-policy";
                kind = "p2p";
                link = "link-upstream-policy";
                endpoints = [
                  {
                    unit = "upstream-1";
                    local = {
                      ipv4 = "169.254.11.0";
                      ipv6 = "fd00:11::0";
                    };
                  }
                  {
                    unit = "policy-1";
                    local = {
                      ipv4 = "169.254.11.1";
                      ipv6 = "fd00:11::1";
                    };
                  }
                ];
              }
              {
                id = "adj::acme.ams::policy-access";
                kind = "p2p";
                link = "link-policy-access";
                endpoints = [
                  {
                    unit = "policy-1";
                    local = {
                      ipv4 = "169.254.10.1";
                      ipv6 = "fd00:10::1";
                    };
                  }
                  {
                    unit = "access-1";
                    local = {
                      ipv4 = "169.254.10.0";
                      ipv6 = "fd00:10::0";
                    };
                  }
                ];
              }
            ];
            ordering = [
              "adj::acme.ams::core-upstream"
              "adj::acme.ams::upstream-policy"
              "adj::acme.ams::policy-access"
            ];
          };

          communicationContract = {
            interfaceTags = {
              tenant0 = "tenant-a";
              uplink0 = "wan";
            };
            allowedRelations = [
              {
                from = {
                  kind = "tenant";
                  name = "tenant-a";
                };
                to = {
                  kind = "external";
                  name = "wan";
                };
                action = "allow";
              }
            ];
          };

          nodes = {
            access-1 = {
              role = "access";
              loopback = {
                ipv4 = "10.255.0.2/32";
                ipv6 = "fd00:ff:1::2/128";
              };
              interfaces = {
                tenant0 = {
                  interface = "tenant-a";
                  kind = "tenant";
                  tenant = "tenant-a";
                  addr4 = "10.20.0.1/24";
                  addr6 = "fd00:20::1/64";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                p2p0 = {
                  interface = "eth-policy";
                  kind = "p2p";
                  link = "link-policy-access";
                  addr4 = "169.254.10.0/31";
                  addr6 = "fd00:10::0/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            policy-1 = {
              role = "policy";
              loopback = {
                ipv4 = "10.255.0.1/32";
                ipv6 = "fd00:ff:1::1/128";
              };
              interfaces = {
                p2p-access = {
                  interface = "eth-access";
                  kind = "p2p";
                  link = "link-policy-access";
                  addr4 = "169.254.10.1/31";
                  addr6 = "fd00:10::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                p2p-upstream = {
                  interface = "eth-upstream";
                  kind = "p2p";
                  link = "link-upstream-policy";
                  addr4 = "169.254.11.1/31";
                  addr6 = "fd00:11::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            core-1 = {
              role = "core";
              loopback = {
                ipv4 = "10.255.0.3/32";
                ipv6 = "fd00:ff:1::3/128";
              };
              interfaces = {
                p2p-upstream = {
                  interface = "eth-upstream";
                  kind = "p2p";
                  link = "link-core-upstream";
                  addr4 = "169.254.12.0/31";
                  addr6 = "fd00:12::0/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                uplink0 = {
                  interface = "wan0";
                  kind = "wan";
                  link = "wan-core";
                  upstream = "wan";
                  addr4 = "192.0.2.2/31";
                  addr6 = "2001:db8:1::2/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            upstream-1 = {
              role = "upstream-selector";
              loopback = {
                ipv4 = "10.255.0.4/32";
                ipv6 = "fd00:ff:1::4/128";
              };
              interfaces = {
                p2p-core = {
                  interface = "eth-core";
                  kind = "p2p";
                  link = "link-core-upstream";
                  addr4 = "169.254.12.1/31";
                  addr6 = "fd00:12::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                p2p-policy = {
                  interface = "eth-policy";
                  kind = "p2p";
                  link = "link-upstream-policy";
                  addr4 = "169.254.11.0/31";
                  addr6 = "fd00:11::0/127";
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

    globex = {
      site = {
        nyc = {
          siteId = "nyc";
          siteName = "globex.nyc";

          attachments = [
            {
              kind = "tenant";
              name = "tenant-b";
              unit = "access-1";
            }
          ];

          policyNodeName = "policy-1";
          upstreamSelectorNodeName = "upstream-1";
          coreNodeNames = [ "core-1" ];
          uplinkCoreNames = [ "core-1" ];
          uplinkNames = [ "wan" ];

          domains = {
            tenants = [
              {
                name = "tenant-b";
                ipv4 = "10.30.0.0/24";
                ipv6 = "fd00:30::/64";
              }
            ];
            externals = [
              {
                name = "wan";
              }
            ];
          };

          tenantPrefixOwners = {
            "4|10.30.0.0/24" = {
              family = 4;
              dst = "10.30.0.0/24";
              netName = "tenant-b";
              owner = "access-1";
            };
          };

          links = {
            link-policy-access = {
              id = "adj::globex.nyc::policy-access";
              kind = "p2p";
              members = [ "policy-1" "access-1" ];
              endpoints = {
                policy-1 = {
                  node = "policy-1";
                  interface = "eth-access";
                  addr4 = "169.254.20.1/31";
                  addr6 = "fd00:20::1/127";
                };
                access-1 = {
                  node = "access-1";
                  interface = "eth-policy";
                  addr4 = "169.254.20.0/31";
                  addr6 = "fd00:20::0/127";
                };
              };
            };

            link-upstream-policy = {
              id = "adj::globex.nyc::upstream-policy";
              kind = "p2p";
              members = [ "upstream-1" "policy-1" ];
              endpoints = {
                upstream-1 = {
                  node = "upstream-1";
                  interface = "eth-policy";
                  addr4 = "169.254.21.0/31";
                  addr6 = "fd00:21::0/127";
                };
                policy-1 = {
                  node = "policy-1";
                  interface = "eth-upstream";
                  addr4 = "169.254.21.1/31";
                  addr6 = "fd00:21::1/127";
                };
              };
            };

            link-core-upstream = {
              id = "adj::globex.nyc::core-upstream";
              kind = "p2p";
              members = [ "core-1" "upstream-1" ];
              endpoints = {
                core-1 = {
                  node = "core-1";
                  interface = "eth-upstream";
                  addr4 = "169.254.22.0/31";
                  addr6 = "fd00:22::0/127";
                };
                upstream-1 = {
                  node = "upstream-1";
                  interface = "eth-core";
                  addr4 = "169.254.22.1/31";
                  addr6 = "fd00:22::1/127";
                };
              };
            };

            wan-core = {
              id = "link::globex.nyc::wan-core";
              kind = "wan";
              members = [ "core-1" ];
              endpoints = {
                core-1 = {
                  node = "core-1";
                  interface = "wan0";
                  addr4 = "198.51.100.2/31";
                  addr6 = "2001:db8:2::2/127";
                };
              };
            };
          };

          transit = {
            adjacencies = [
              {
                id = "adj::globex.nyc::core-upstream";
                kind = "p2p";
                link = "link-core-upstream";
                endpoints = [
                  {
                    unit = "core-1";
                    local = {
                      ipv4 = "169.254.22.0";
                      ipv6 = "fd00:22::0";
                    };
                  }
                  {
                    unit = "upstream-1";
                    local = {
                      ipv4 = "169.254.22.1";
                      ipv6 = "fd00:22::1";
                    };
                  }
                ];
              }
              {
                id = "adj::globex.nyc::upstream-policy";
                kind = "p2p";
                link = "link-upstream-policy";
                endpoints = [
                  {
                    unit = "upstream-1";
                    local = {
                      ipv4 = "169.254.21.0";
                      ipv6 = "fd00:21::0";
                    };
                  }
                  {
                    unit = "policy-1";
                    local = {
                      ipv4 = "169.254.21.1";
                      ipv6 = "fd00:21::1";
                    };
                  }
                ];
              }
              {
                id = "adj::globex.nyc::policy-access";
                kind = "p2p";
                link = "link-policy-access";
                endpoints = [
                  {
                    unit = "policy-1";
                    local = {
                      ipv4 = "169.254.20.1";
                      ipv6 = "fd00:20::1";
                    };
                  }
                  {
                    unit = "access-1";
                    local = {
                      ipv4 = "169.254.20.0";
                      ipv6 = "fd00:20::0";
                    };
                  }
                ];
              }
            ];
            ordering = [
              "adj::globex.nyc::core-upstream"
              "adj::globex.nyc::upstream-policy"
              "adj::globex.nyc::policy-access"
            ];
          };

          communicationContract = {
            interfaceTags = {
              tenant0 = "tenant-b";
              uplink0 = "wan";
            };
            allowedRelations = [
              {
                from = {
                  kind = "tenant";
                  name = "tenant-b";
                };
                to = {
                  kind = "external";
                  name = "wan";
                };
                action = "allow";
              }
            ];
          };

          nodes = {
            access-1 = {
              role = "access";
              loopback = {
                ipv4 = "10.255.1.2/32";
                ipv6 = "fd00:ff:2::2/128";
              };
              interfaces = {
                tenant0 = {
                  interface = "tenant-b";
                  kind = "tenant";
                  tenant = "tenant-b";
                  addr4 = "10.30.0.1/24";
                  addr6 = "fd00:30::1/64";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                p2p0 = {
                  interface = "eth-policy";
                  kind = "p2p";
                  link = "link-policy-access";
                  addr4 = "169.254.20.0/31";
                  addr6 = "fd00:20::0/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            policy-1 = {
              role = "policy";
              loopback = {
                ipv4 = "10.255.1.1/32";
                ipv6 = "fd00:ff:2::1/128";
              };
              interfaces = {
                p2p-access = {
                  interface = "eth-access";
                  kind = "p2p";
                  link = "link-policy-access";
                  addr4 = "169.254.20.1/31";
                  addr6 = "fd00:20::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                p2p-upstream = {
                  interface = "eth-upstream";
                  kind = "p2p";
                  link = "link-upstream-policy";
                  addr4 = "169.254.21.1/31";
                  addr6 = "fd00:21::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            core-1 = {
              role = "core";
              loopback = {
                ipv4 = "10.255.1.3/32";
                ipv6 = "fd00:ff:2::3/128";
              };
              interfaces = {
                p2p-upstream = {
                  interface = "eth-upstream";
                  kind = "p2p";
                  link = "link-core-upstream";
                  addr4 = "169.254.22.0/31";
                  addr6 = "fd00:22::0/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                uplink0 = {
                  interface = "wan0";
                  kind = "wan";
                  link = "wan-core";
                  upstream = "wan";
                  addr4 = "198.51.100.2/31";
                  addr6 = "2001:db8:2::2/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            upstream-1 = {
              role = "upstream-selector";
              loopback = {
                ipv4 = "10.255.1.4/32";
                ipv6 = "fd00:ff:2::4/128";
              };
              interfaces = {
                p2p-core = {
                  interface = "eth-core";
                  kind = "p2p";
                  link = "link-core-upstream";
                  addr4 = "169.254.22.1/31";
                  addr6 = "fd00:22::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                p2p-policy = {
                  interface = "eth-policy";
                  kind = "p2p";
                  link = "link-upstream-policy";
                  addr4 = "169.254.21.0/31";
                  addr6 = "fd00:21::0/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };
          };
        };

        lon = {
          siteId = "lon";
          siteName = "globex.lon";

          attachments = [
            {
              kind = "tenant";
              name = "tenant-c";
              unit = "access-1";
            }
          ];

          policyNodeName = "policy-1";
          upstreamSelectorNodeName = "upstream-1";
          coreNodeNames = [ "core-1" ];
          uplinkCoreNames = [ "core-1" ];
          uplinkNames = [ ];

          domains = {
            tenants = [
              {
                name = "tenant-c";
                ipv4 = "10.40.0.0/24";
                ipv6 = "fd00:40::/64";
              }
            ];
            externals = [ ];
          };

          tenantPrefixOwners = {
            "4|10.40.0.0/24" = {
              family = 4;
              dst = "10.40.0.0/24";
              netName = "tenant-c";
              owner = "access-1";
            };
          };

          links = {
            link-policy-access = {
              id = "adj::globex.lon::policy-access";
              kind = "p2p";
              members = [ "policy-1" "access-1" ];
              endpoints = {
                policy-1 = {
                  node = "policy-1";
                  interface = "eth-access";
                  addr4 = "169.254.30.1/31";
                  addr6 = "fd00:30::1/127";
                };
                access-1 = {
                  node = "access-1";
                  interface = "eth-policy";
                  addr4 = "169.254.30.0/31";
                  addr6 = "fd00:30::0/127";
                };
              };
            };

            link-upstream-policy = {
              id = "adj::globex.lon::upstream-policy";
              kind = "p2p";
              members = [ "upstream-1" "policy-1" ];
              endpoints = {
                upstream-1 = {
                  node = "upstream-1";
                  interface = "eth-policy";
                  addr4 = "169.254.31.0/31";
                  addr6 = "fd00:31::0/127";
                };
                policy-1 = {
                  node = "policy-1";
                  interface = "eth-upstream";
                  addr4 = "169.254.31.1/31";
                  addr6 = "fd00:31::1/127";
                };
              };
            };

            link-core-upstream = {
              id = "adj::globex.lon::core-upstream";
              kind = "p2p";
              members = [ "core-1" "upstream-1" ];
              endpoints = {
                core-1 = {
                  node = "core-1";
                  interface = "eth-upstream";
                  addr4 = "169.254.32.0/31";
                  addr6 = "fd00:32::0/127";
                };
                upstream-1 = {
                  node = "upstream-1";
                  interface = "eth-core";
                  addr4 = "169.254.32.1/31";
                  addr6 = "fd00:32::1/127";
                };
              };
            };
          };

          transit = {
            adjacencies = [
              {
                id = "adj::globex.lon::core-upstream";
                kind = "p2p";
                link = "link-core-upstream";
                endpoints = [
                  {
                    unit = "core-1";
                    local = {
                      ipv4 = "169.254.32.0";
                      ipv6 = "fd00:32::0";
                    };
                  }
                  {
                    unit = "upstream-1";
                    local = {
                      ipv4 = "169.254.32.1";
                      ipv6 = "fd00:32::1";
                    };
                  }
                ];
              }
              {
                id = "adj::globex.lon::upstream-policy";
                kind = "p2p";
                link = "link-upstream-policy";
                endpoints = [
                  {
                    unit = "upstream-1";
                    local = {
                      ipv4 = "169.254.31.0";
                      ipv6 = "fd00:31::0";
                    };
                  }
                  {
                    unit = "policy-1";
                    local = {
                      ipv4 = "169.254.31.1";
                      ipv6 = "fd00:31::1";
                    };
                  }
                ];
              }
              {
                id = "adj::globex.lon::policy-access";
                kind = "p2p";
                link = "link-policy-access";
                endpoints = [
                  {
                    unit = "policy-1";
                    local = {
                      ipv4 = "169.254.30.1";
                      ipv6 = "fd00:30::1";
                    };
                  }
                  {
                    unit = "access-1";
                    local = {
                      ipv4 = "169.254.30.0";
                      ipv6 = "fd00:30::0";
                    };
                  }
                ];
              }
            ];
            ordering = [
              "adj::globex.lon::core-upstream"
              "adj::globex.lon::upstream-policy"
              "adj::globex.lon::policy-access"
            ];
          };

          communicationContract = {
            interfaceTags = {
              tenant0 = "tenant-c";
            };
            allowedRelations = [
              {
                from = {
                  kind = "tenant";
                  name = "tenant-c";
                };
                to = "any";
                action = "allow";
              }
            ];
          };

          nodes = {
            access-1 = {
              role = "access";
              loopback = {
                ipv4 = "10.255.2.2/32";
                ipv6 = "fd00:ff:3::2/128";
              };
              interfaces = {
                tenant0 = {
                  interface = "tenant-c";
                  kind = "tenant";
                  tenant = "tenant-c";
                  addr4 = "10.40.0.1/24";
                  addr6 = "fd00:40::1/64";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                p2p0 = {
                  interface = "eth-policy";
                  kind = "p2p";
                  link = "link-policy-access";
                  addr4 = "169.254.30.0/31";
                  addr6 = "fd00:30::0/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            policy-1 = {
              role = "policy";
              loopback = {
                ipv4 = "10.255.2.1/32";
                ipv6 = "fd00:ff:3::1/128";
              };
              interfaces = {
                p2p-access = {
                  interface = "eth-access";
                  kind = "p2p";
                  link = "link-policy-access";
                  addr4 = "169.254.30.1/31";
                  addr6 = "fd00:30::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                p2p-upstream = {
                  interface = "eth-upstream";
                  kind = "p2p";
                  link = "link-upstream-policy";
                  addr4 = "169.254.31.1/31";
                  addr6 = "fd00:31::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            core-1 = {
              role = "core";
              loopback = {
                ipv4 = "10.255.2.3/32";
                ipv6 = "fd00:ff:3::3/128";
              };
              interfaces = {
                p2p-upstream = {
                  interface = "eth-upstream";
                  kind = "p2p";
                  link = "link-core-upstream";
                  addr4 = "169.254.32.0/31";
                  addr6 = "fd00:32::0/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                overlay0 = {
                  interface = "nebula0";
                  kind = "overlay";
                  overlay = "nebula-east-west";
                  addr4 = null;
                  addr6 = null;
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
              };
            };

            upstream-1 = {
              role = "upstream-selector";
              loopback = {
                ipv4 = "10.255.2.4/32";
                ipv6 = "fd00:ff:3::4/128";
              };
              interfaces = {
                p2p-core = {
                  interface = "eth-core";
                  kind = "p2p";
                  link = "link-core-upstream";
                  addr4 = "169.254.32.1/31";
                  addr6 = "fd00:32::1/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
                p2p-policy = {
                  interface = "eth-policy";
                  kind = "p2p";
                  link = "link-upstream-policy";
                  addr4 = "169.254.31.0/31";
                  addr6 = "fd00:31::0/127";
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
