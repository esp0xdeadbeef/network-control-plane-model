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
            "6|fd00:20::/64" = {
              family = 6;
              dst = "fd00:20::/64";
              netName = "tenant-a";
              owner = "access-1";
            };
          };

          egressIntent = {
            explicit = true;
            eligibleNodeNames = [ "core-1" "upstream-1" ];
            exitNodeNames = [ "core-1" ];
            externalDomains = [ "wan" ];
            uplinkCoreNodeNames = [ "core-1" ];
            upstreamSelectorNodeName = "upstream-1";
          };

          forwardingSemantics = {
            explicit = true;
            coreNodeNames = [ "core-1" ];
            policyNodeName = "policy-1";
            traversalParticipantNodeNames = [
              "access-1"
              "policy-1"
              "upstream-1"
              "core-1"
            ];
            upstreamSelectorNodeName = "upstream-1";
            nodes = {
              access-1 = {
                routingAuthority = {
                  connectedReachability = true;
                  defaultReachability = false;
                  exitsSite = false;
                  explicit = true;
                  internalReachability = true;
                  overlayReachability = false;
                  selectsUpstream = false;
                  uplinkLearnedReachability = false;
                };
              };

              policy-1 = {
                routingAuthority = {
                  connectedReachability = true;
                  defaultReachability = false;
                  exitsSite = false;
                  explicit = true;
                  internalReachability = true;
                  overlayReachability = false;
                  selectsUpstream = false;
                  uplinkLearnedReachability = false;
                };
              };

              upstream-1 = {
                routingAuthority = {
                  connectedReachability = true;
                  defaultReachability = false;
                  exitsSite = false;
                  explicit = true;
                  internalReachability = true;
                  overlayReachability = false;
                  selectsUpstream = true;
                  uplinkLearnedReachability = false;
                };
              };

              core-1 = {
                egressIntent = {
                  eligible = true;
                  exit = true;
                  explicit = true;
                  externalDomains = [ "wan" ];
                  uplinks = [ "wan" ];
                  upstreamSelection = false;
                  wanInterfaces = [ "uplink0" ];
                };
                routingAuthority = {
                  connectedReachability = true;
                  defaultReachability = false;
                  exitsSite = true;
                  explicit = true;
                  internalReachability = true;
                  overlayReachability = false;
                  selectsUpstream = false;
                  uplinkLearnedReachability = false;
                };
              };
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
              routingAuthority = {
                connectedReachability = true;
                defaultReachability = false;
                exitsSite = false;
                explicit = true;
                internalReachability = true;
                overlayReachability = false;
                selectsUpstream = false;
                uplinkLearnedReachability = false;
              };
              interfaces = {
                tenant0 = {
                  interface = "tenant-a";
                  kind = "tenant";
                  tenant = "tenant-a";
                  addr4 = "10.20.0.1/24";
                  addr6 = "fd00:20::1/64";
                  routes = {
                    ipv4 = [
                      {
                        dst = "10.20.0.0/24";
                        intent = {
                          kind = "connected-reachability";
                        };
                        proto = "connected";
                      }
                    ];
                    ipv6 = [
                      {
                        dst = "fd00:20::/64";
                        intent = {
                          kind = "connected-reachability";
                        };
                        proto = "connected";
                      }
                    ];
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
              routingAuthority = {
                connectedReachability = true;
                defaultReachability = false;
                exitsSite = false;
                explicit = true;
                internalReachability = true;
                overlayReachability = false;
                selectsUpstream = false;
                uplinkLearnedReachability = false;
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

            upstream-1 = {
              role = "upstream-selector";
              egressIntent = {
                eligible = true;
                exit = false;
                explicit = true;
                externalDomains = [ "wan" ];
                uplinks = [ "wan" ];
                upstreamSelection = true;
                wanInterfaces = [ ];
              };
              loopback = {
                ipv4 = "10.255.0.4/32";
                ipv6 = "fd00:ff:1::4/128";
              };
              routingAuthority = {
                connectedReachability = true;
                defaultReachability = false;
                exitsSite = false;
                explicit = true;
                internalReachability = true;
                overlayReachability = false;
                selectsUpstream = true;
                uplinkLearnedReachability = false;
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

            core-1 = {
              role = "core";
              egressIntent = {
                eligible = true;
                exit = true;
                explicit = true;
                externalDomains = [ "wan" ];
                uplinks = [ "wan" ];
                upstreamSelection = false;
                wanInterfaces = [ "uplink0" ];
              };
              loopback = {
                ipv4 = "10.255.0.3/32";
                ipv6 = "fd00:ff:1::3/128";
              };
              routingAuthority = {
                connectedReachability = true;
                defaultReachability = false;
                exitsSite = true;
                explicit = true;
                internalReachability = true;
                overlayReachability = false;
                selectsUpstream = false;
                uplinkLearnedReachability = false;
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
                  wan = {
                    ipv4 = [ "0.0.0.0/0" ];
                    ipv6 = [ "::/0" ];
                  };
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
