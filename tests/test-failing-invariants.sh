#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
  expr="let input = import ${tmp_dir}/input.nix; inventory = import ${tmp_dir}/inventory.nix; in import ${repo_root}/src/main.nix { inherit input inventory; }"

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
  "unsupported forwarding model schema version '5' (expected 6)" \
  "$(cat <<'EOF'
{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 5;
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
      schemaVersion = 6;
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
      schemaVersion = 6;
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

exit "${status}"
