#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

status=0

run_case() {
  local name="$1"
  local expected="$2"
  local input_nix="$3"
  local inventory_nix="$4"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  printf '%s\n' "$input_nix" > "${tmp_dir}/input.nix"
  printf '%s\n' "$inventory_nix" > "${tmp_dir}/inventory.nix"

  local stderr_file
  stderr_file="$(mktemp)"

  local expr
  expr="let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${tmp_dir}/input.nix;
    inventory = import ${tmp_dir}/inventory.nix;
  in
    builder { inherit input inventory; }"

  if nix eval --show-trace --impure --json --expr "${expr}" >/dev/null 2>"${stderr_file}"; then
    echo "FAIL ${name}: evaluation unexpectedly succeeded"
    echo "--- input.nix ---"
    cat "${tmp_dir}/input.nix"
    echo "--- inventory.nix ---"
    cat "${tmp_dir}/inventory.nix"
    status=1
  else
    if grep -Fq "${expected}" "${stderr_file}"; then
      echo "PASS ${name}"
    else
      echo "FAIL ${name}: missing expected error"
      echo "expected: ${expected}"
      echo "--- input.nix ---"
      cat "${tmp_dir}/input.nix"
      echo "--- inventory.nix ---"
      cat "${tmp_dir}/inventory.nix"
      echo "--- nix eval expr ---"
      printf '%s\n' "${expr}"
      echo "--- stderr (show-trace) ---"
      cat "${stderr_file}"
      status=1
    fi
  fi

  rm -f "${stderr_file}"
  rm -rf "${tmp_dir}"
  trap - RETURN
}

inventory_empty='{}'

run_case \
  "missing-meta-network-forwarding-model" \
  "forwarding model input requires meta.networkForwardingModel" \
  "$(cat <<'EOF'
{
  enterprise = {
    acme = {
      site = {
        ams = {};
      };
    };
  };
}
EOF
)" \
  "${inventory_empty}"

run_case \
  "unsupported-schema-version" \
  "unsupported forwarding model schema version '9' (expected 8)" \
  "$(cat <<'EOF'
{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 9;
    };
  };

  enterprise = {
    acme = {
      site = {
        ams = {};
      };
    };
  };
}
EOF
)" \
  "${inventory_empty}"

run_case \
  "legacy-singular-attachment" \
  "legacy singular attachment is not supported; use attachments" \
  "$(cat <<'EOF'
{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 8;
    };
  };

  enterprise = {
    acme = {
      site = {
        ams = {
          attachment = {
            kind = "tenant";
            name = "tenant-a";
            unit = "access-1";
          };
        };
      };
    };
  };
}
EOF
)" \
  "${inventory_empty}"

run_case \
  "missing-node-loopback" \
  "node loopback is required" \
  "$(cat <<'EOF'
{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 8;
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
              }
            ];
            ordering = [ "link::acme.ams::policy-access" ];
          };

          communicationContract = {
            allowedRelations = [];
          };

          policy = {
            interfaceTags = {
              tenant0 = "tenant-a";
              wan0 = "wan";
            };
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
              interfaces = {
                p2p0 = {
                  interface = "eth-transit";
                  kind = "p2p";
                  link = "link-policy-access";
                  addr4 = "169.254.0.0/31";
                  addr6 = "fd00:1::0/127";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };
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
              };
            };

            policy-1 = {
              role = "policy";
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
)" \
  "${inventory_empty}"

run_case \
  "core-exit-intent-requires-realized-wan-interface-before-rendering" \
  "control plane model validation failure: core exit intent requires a realized WAN interface before rendering" \
  "$(cat <<'EOF'
{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 8;
    };
  };

  enterprise = {
    acme = {
      site = {
        ams = {
          siteId = "ams";
          siteName = "acme.ams";
          attachments = [ ];
          policyNodeName = "policy-1";
          upstreamSelectorNodeName = "upstream-1";
          coreNodeNames = [ "core-1" ];
          uplinkCoreNames = [ "core-1" ];
          uplinkNames = [ "wan" ];
          domains = {
            tenants = [ ];
            externals = [
              {
                name = "wan";
              }
            ];
          };
          tenantPrefixOwners = { };
          links = {
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
            ];
            ordering = [ "adj::acme.ams::core-upstream" ];
          };
          communicationContract = {
            allowedRelations = [ ];
          };
          policy = {
            interfaceTags = { };
          };
          nodes = {
            policy-1 = {
              role = "policy";
              loopback = {
                ipv4 = "10.255.0.1/32";
                ipv6 = "fd00:ff::1/128";
              };
              interfaces = { };
            };

            upstream-1 = {
              role = "upstream-selector";
              loopback = {
                ipv4 = "10.255.0.2/32";
                ipv6 = "fd00:ff::2/128";
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
              };
            };

            core-1 = {
              role = "core";
              egressIntent = {
                exit = true;
                uplinks = [ "wan" ];
                wanInterfaces = [ "wan" ];
              };
              loopback = {
                ipv4 = "10.255.0.3/32";
                ipv6 = "fd00:ff::3/128";
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
              };
            };
          };
        };
      };
    };
  };
}
EOF
)" \
  "${inventory_empty}"

run_case \
  "core-role-requires-two-adapters-before-rendering" \
  "control plane model validation failure: core role requires at least two adapters before rendering" \
  "$(cat <<'EOF'
{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 8;
    };
  };

  enterprise = {
    acme = {
      site = {
        ams = {
          siteId = "ams";
          siteName = "acme.ams";
          attachments = [ ];
          policyNodeName = "policy-1";
          upstreamSelectorNodeName = "upstream-1";
          coreNodeNames = [ "core-1" ];
          uplinkCoreNames = [ "core-1" ];
          uplinkNames = [ "wan" ];
          domains = {
            tenants = [ ];
            externals = [
              {
                name = "wan";
              }
            ];
          };
          tenantPrefixOwners = { };
          links = {
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
            adjacencies = [ ];
            ordering = [ ];
          };
          communicationContract = {
            allowedRelations = [ ];
          };
          policy = {
            interfaceTags = {
              uplink0 = "wan";
            };
          };
          nodes = {
            policy-1 = {
              role = "policy";
              loopback = {
                ipv4 = "10.255.0.1/32";
                ipv6 = "fd00:ff::1/128";
              };
              interfaces = { };
            };

            upstream-1 = {
              role = "upstream-selector";
              loopback = {
                ipv4 = "10.255.0.2/32";
                ipv6 = "fd00:ff::2/128";
              };
              interfaces = { };
            };

            core-1 = {
              role = "core";
              loopback = {
                ipv4 = "10.255.0.3/32";
                ipv6 = "fd00:ff::3/128";
              };
              interfaces = {
                uplink0 = {
                  interface = "wan0";
                  kind = "wan";
                  link = "wan-core";
                  upstream = "wan";
                  addr4 = "192.0.2.2/31";
                  addr6 = "2001:db8::2/127";
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
EOF
)" \
  "$(cat <<'EOF'
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
          };
        };
      };
    };
  };

  realization = {
    nodes = {
      core-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "acme";
          site = "ams";
          name = "core-1";
        };
        ports = {
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
    };
  };
}
EOF
)"

exit "${status}"
