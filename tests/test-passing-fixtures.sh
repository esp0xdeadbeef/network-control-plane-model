# ./tests/test-passing-fixtures.sh
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

status=0

run_case() {
  local name="$1"
  local input_nix="$2"
  local inventory_nix="$3"
  local validator="$4"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  printf '%s\n' "$input_nix" > "${tmp_dir}/input.nix"
  printf '%s\n' "$inventory_nix" > "${tmp_dir}/inventory.nix"

  local output_json
  output_json="$(mktemp)"

  local expr
  expr="let input = import ${tmp_dir}/input.nix; inventory = import ${tmp_dir}/inventory.nix; in import ${repo_root}/src/main.nix { inherit input inventory; }"

  if ! nix eval --impure --json --expr "${expr}" >"${output_json}"; then
    echo "FAIL ${name}: evaluation failed"
    status=1
    rm -f "${output_json}"
    rm -rf "${tmp_dir}"
    trap - RETURN
    return
  fi

  case "${validator}" in
    minimal-forwarding-model-v6)
      if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
        let
          data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
          cpm = data.control_plane_model;
          site = cpm.data.acme.ams;
          accessTarget = site.runtimeTargets.access-1;
          transitIface = accessTarget.effectiveRuntimeRealization.interfaces.p2p0;
          tenantIface = accessTarget.effectiveRuntimeRealization.interfaces.tenant0;
        in
          builtins.isAttrs cpm
          && (cpm.version or null) == 1
          && (cpm.source or null) == "nix"
          && (cpm.inputContract.schemaVersion or null) == 6
          && builtins.isAttrs site
          && builtins.isAttrs (site.runtimeTargets or null)
          && (transitIface.backingRef.kind or null) == "link"
          && (transitIface.backingRef.id or null) == "link::acme.ams::policy-access"
          && (tenantIface.backingRef.kind or null) == "attachment"
          && (accessTarget.effectiveRuntimeRealization.loopback.addr4 or null) == "10.255.0.2/32"
      ' >/dev/null; then
        echo "FAIL ${name}: JSON validation failed"
        status=1
      else
        echo "PASS ${name}"
      fi
      ;;
    hosted-runtime-targets)
      if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
        let
          data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
          cpm = data.control_plane_model;
          site = cpm.data.esp0xdeadbeef.site-a;
          edgeTarget = site.runtimeTargets.s-router-edge-runtime;
          policyTarget = site.runtimeTargets.s-router-policy-runtime;
          edgeIface = edgeTarget.effectiveRuntimeRealization.interfaces.p2p0;
          policyIface = policyTarget.effectiveRuntimeRealization.interfaces.p2p0;
        in
          builtins.isAttrs cpm
          && (cpm.inputContract.schemaVersion or null) == 6
          && builtins.isAttrs site
          && (edgeTarget.placement.kind or null) == "inventory-realization"
          && (edgeTarget.placement.host or null) == "hypervisor-b"
          && (edgeIface.runtimeIfName or null) == "ens4"
          && (policyIface.runtimeIfName or null) == "ens3"
          && (edgeIface.backingRef.id or null) == "link::esp0xdeadbeef.site-a::transit-policy-edge"
          && (policyIface.backingRef.id or null) == "link::esp0xdeadbeef.site-a::transit-policy-edge"
      ' >/dev/null; then
        echo "FAIL ${name}: JSON validation failed"
        status=1
      else
        echo "PASS ${name}"
      fi
      ;;
    *)
      echo "FAIL ${name}: unknown validator '${validator}'"
      status=1
      ;;
  esac

  rm -f "${output_json}"
  rm -rf "${tmp_dir}"
  trap - RETURN
}

minimal_input="$(cat <<'EOF'
{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 6;
      gitRev = "deadbeef";
      gitDirty = true;
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
              id = "link::acme.ams::policy-access";
              kind = "p2p";
              members = [ "policy-1" "access-1" ];
              endpoints = {
                policy-1 = {
                  node = "policy-1";
                  interface = "eth-transit";
                  addr4 = "169.254.0.1/31";
                  addr6 = "fd00:1::1/127";
                };
                access-1 = {
                  node = "access-1";
                  interface = "eth-transit";
                  addr4 = "169.254.0.0/31";
                  addr6 = "fd00:1::0/127";
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
                  addr6 = "2001:db8::2/127";
                };
              };
            };
          };

          transit = {
            adjacencies = [
              {
                id = "link::acme.ams::policy-access";
                kind = "p2p";
                link = "link-policy-access";
                name = "link-policy-access";
                members = [ "policy-1" "access-1" ];
                endpoints = [
                  {
                    unit = "policy-1";
                    local = {
                      ipv4 = "169.254.0.1";
                      ipv6 = "fd00:1::1";
                    };
                  }
                  {
                    unit = "access-1";
                    local = {
                      ipv4 = "169.254.0.0";
                      ipv6 = "fd00:1::0";
                    };
                  }
                ];
                routingParticipation = false;
              }
            ];
            ordering = [ "link::acme.ams::policy-access" ];
          };

          nodes = {
            access-1 = {
              role = "access";
              attachments = [
                {
                  kind = "tenant";
                  name = "tenant-a";
                }
              ];
              containers = [ "default" ];
              loopback = {
                ipv4 = "10.255.0.2/32";
                ipv6 = "fd00:ff::2/128";
              };
              interfaces = {
                p2p0 = {
                  interface = "eth-transit";
                  kind = "p2p";
                  link = "link-policy-access";
                  addr4 = "169.254.0.0/31";
                  addr6 = "fd00:1::0/127";
                  routes = {
                    ipv4 = [
                      {
                        dst = "0.0.0.0/0";
                        proto = "default";
                        via4 = "169.254.0.1";
                      }
                    ];
                    ipv6 = [
                      {
                        dst = "::/0";
                        proto = "default";
                        via6 = "fd00:1::1";
                      }
                    ];
                  };
                };

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
                        proto = "connected";
                      }
                    ];
                    ipv6 = [
                      {
                        dst = "fd00:20::/64";
                        proto = "connected";
                      }
                    ];
                  };
                };
              };
            };

            policy-1 = {
              role = "policy";
              containers = [ "default" ];
              loopback = {
                ipv4 = "10.255.0.1/32";
                ipv6 = "fd00:ff::1/128";
              };
              interfaces = {
                p2p0 = {
                  interface = "eth-transit";
                  kind = "p2p";
                  link = "link-policy-access";
                  addr4 = "169.254.0.1/31";
                  addr6 = "fd00:1::1/127";
                  routes = {
                    ipv4 = [
                      {
                        dst = "169.254.0.0/31";
                        proto = "connected";
                      }
                    ];
                    ipv6 = [
                      {
                        dst = "fd00:1::/127";
                        proto = "connected";
                      }
                    ];
                  };
                };
              };
            };

            core-1 = {
              role = "core";
              containers = [ "default" ];
              loopback = {
                ipv4 = "10.255.0.3/32";
                ipv6 = "fd00:ff::3/128";
              };
              interfaces = {
                wan0 = {
                  interface = "wan0";
                  kind = "wan";
                  link = "wan-core";
                  upstream = "wan";
                  addr4 = "192.0.2.2/31";
                  addr6 = "2001:db8::2/127";
                  routes = {
                    ipv4 = [
                      {
                        dst = "0.0.0.0/0";
                        proto = "uplink";
                        via4 = "192.0.2.3";
                      }
                    ];
                    ipv6 = [
                      {
                        dst = "::/0";
                        proto = "uplink";
                        via6 = "2001:db8::3";
                      }
                    ];
                  };
                };
              };
            };

            upstream-1 = {
              role = "upstream-selector";
              containers = [ "default" ];
              loopback = {
                ipv4 = "10.255.0.4/32";
                ipv6 = "fd00:ff::4/128";
              };
              interfaces = {};
            };
          };
        };
      };
    };
  };
}
EOF
)"

hosted_input="$(cat <<'EOF'
{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 6;
      gitRev = "deadbeef";
      gitDirty = true;
    };
  };

  enterprise = {
    esp0xdeadbeef = {
      site = {
        site-a = {
          siteId = "site-a";
          siteName = "esp0xdeadbeef.site-a";

          attachments = [];

          policyNodeName = "s-router-policy";
          upstreamSelectorNodeName = "s-router-edge";
          coreNodeNames = [ "s-router-edge" ];
          uplinkCoreNames = [ "s-router-edge" ];
          uplinkNames = [ "wan" ];

          domains = {
            tenants = [];
            externals = [
              {
                name = "wan";
              }
            ];
          };

          tenantPrefixOwners = {};

          links = {
            transit-policy-edge = {
              id = "link::esp0xdeadbeef.site-a::transit-policy-edge";
              kind = "p2p";
              members = [ "s-router-policy" "s-router-edge" ];
              endpoints = {
                s-router-policy = {
                  node = "s-router-policy";
                  interface = "eth-transit";
                  addr4 = "169.254.100.1/31";
                  addr6 = "fd42:1::1/127";
                };
                s-router-edge = {
                  node = "s-router-edge";
                  interface = "eth-transit";
                  addr4 = "169.254.100.0/31";
                  addr6 = "fd42:1::/127";
                };
              };
            };
          };

          transit = {
            adjacencies = [
              {
                id = "link::esp0xdeadbeef.site-a::transit-policy-edge";
                kind = "p2p";
                link = "transit-policy-edge";
                endpoints = [
                  {
                    unit = "s-router-policy";
                    local = {
                      ipv4 = "169.254.100.1";
                      ipv6 = "fd42:1::1";
                    };
                  }
                  {
                    unit = "s-router-edge";
                    local = {
                      ipv4 = "169.254.100.0";
                      ipv6 = "fd42:1::";
                    };
                  }
                ];
                routingParticipation = false;
              }
            ];
            ordering = [ "link::esp0xdeadbeef.site-a::transit-policy-edge" ];
          };

          nodes = {
            s-router-policy = {
              role = "policy";
              containers = [ "default" ];
              loopback = {
                ipv4 = "10.19.0.9/32";
                ipv6 = "fd42:dead:beef:1900::9/128";
              };
              interfaces = {
                p2p0 = {
                  interface = "eth-transit";
                  kind = "p2p";
                  link = "transit-policy-edge";
                  addr4 = "169.254.100.1/31";
                  addr6 = "fd42:1::1/127";
                  routes = {
                    ipv4 = [
                      {
                        dst = "169.254.100.0/31";
                        proto = "connected";
                      }
                    ];
                    ipv6 = [
                      {
                        dst = "fd42:1::/127";
                        proto = "connected";
                      }
                    ];
                  };
                };
              };
            };

            s-router-edge = {
              role = "core";
              containers = [ "default" ];
              loopback = {
                ipv4 = "10.19.0.8/32";
                ipv6 = "fd42:dead:beef:1900::8/128";
              };
              interfaces = {
                p2p0 = {
                  interface = "eth-transit";
                  kind = "p2p";
                  link = "transit-policy-edge";
                  addr4 = "169.254.100.0/31";
                  addr6 = "fd42:1::/127";
                  routes = {
                    ipv4 = [
                      {
                        dst = "169.254.100.0/31";
                        proto = "connected";
                      }
                    ];
                    ipv6 = [
                      {
                        dst = "fd42:1::/127";
                        proto = "connected";
                      }
                    ];
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
EOF
)"

hosted_inventory="$(cat <<'EOF'
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
      s-router-policy-runtime = {
        host = "hypervisor-a";
        platform = "linux";

        logicalNode = {
          enterprise = "esp0xdeadbeef";
          site = "site-a";
          name = "s-router-policy";
        };

        ports = {
          wan0 = {
            link = "link::esp0xdeadbeef.site-a::transit-policy-edge";
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

      s-router-edge-runtime = {
        host = "hypervisor-b";
        platform = "linux";

        logicalNode = {
          enterprise = "esp0xdeadbeef";
          site = "site-a";
          name = "s-router-edge";
        };

        ports = {
          wan0 = {
            link = "link::esp0xdeadbeef.site-a::transit-policy-edge";
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
EOF
)"

run_case \
  "minimal-forwarding-model-v6" \
  "${minimal_input}" \
  "{}" \
  "minimal-forwarding-model-v6"

run_case \
  "hosted-runtime-targets" \
  "${hosted_input}" \
  "${hosted_inventory}" \
  "hosted-runtime-targets"

exit "${status}"
