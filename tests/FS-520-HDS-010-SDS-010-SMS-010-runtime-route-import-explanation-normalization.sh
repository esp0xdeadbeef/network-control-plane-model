#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: FS-520-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

input_nix="${tmp_dir}/runtime-route-import-explanation-input.nix"
inventory_nix="${tmp_dir}/runtime-route-import-explanation-inventory.nix"
output_json="${tmp_dir}/runtime-route-import-explanation-cpm.json"
fixture_input="${repo_root}/fixtures/passing/default-egress-reachability/input.nix"
fixture_inventory="${repo_root}/fixtures/passing/default-egress-reachability/inventory.nix"

cat >"${input_nix}" <<NIX
let
  base = import ${fixture_input};
  site = base.enterprise.acme.site.ams;
  core = site.nodes.core-1;
  uplink = core.interfaces.uplink0;
in
base // {
  enterprise = base.enterprise // {
    acme = base.enterprise.acme // {
      site = base.enterprise.acme.site // {
        ams = site // {
          nodes = site.nodes // {
            core-1 =
              core
              // {
                interfaces = core.interfaces // {
                  uplink0 =
                    uplink
                    // {
                      routes = {
                        ipv4 = [
                          {
                            dst = "198.51.100.0/24";
                            proto = "upstream";
                            intent = {
                              kind = "uplink-learned-reachability";
                              source = "explicit-uplink";
                            };
                          }
                        ];
                        ipv6 = [
                          {
                            dst = "2001:db8:51::/48";
                            proto = "upstream";
                            intent = {
                              kind = "uplink-learned-reachability";
                              source = "explicit-uplink";
                            };
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
NIX

cat >"${inventory_nix}" <<NIX
let
  base = import ${fixture_inventory};
  dnsPolicy = ipv4: ipv6: {
    listen = [ ipv4 ipv6 ];
    allowFrom = [
      (builtins.replaceStrings [ ".1" ] [ ".0/24" ] ipv4)
      (builtins.replaceStrings [ "::1" ] [ "::/64" ] ipv6)
    ];
    forwarders = [ "1.1.1.1" "2606:4700:4700::1111" ];
  };
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime =
        base.realization.nodes.access-runtime
        // {
          services = (base.realization.nodes.access-runtime.services or { }) // {
            dns = dnsPolicy "10.20.0.1" "fd00:20::1";
          };
        };
      globex-nyc-access-runtime =
        base.realization.nodes.globex-nyc-access-runtime
        // {
          services = (base.realization.nodes.globex-nyc-access-runtime.services or { }) // {
            dns = dnsPolicy "10.30.0.1" "fd00:30::1";
          };
        };
      globex-lon-access-runtime =
        base.realization.nodes.globex-lon-access-runtime
        // {
          services = (base.realization.nodes.globex-lon-access-runtime.services or { }) // {
            dns = dnsPolicy "10.40.0.1" "fd00:40::1";
          };
        };
    };
  };
}
NIX

nix eval \
  --impure \
  --json \
  --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      builder = flake.lib.${system}.build;
      input = import ${input_nix};
      inventory = import ${inventory_nix};
    in
      builder { inherit input inventory; }
  " >"${output_json}"

jq -e '
  .control_plane_model.data.acme.ams.runtimeTargets."core-runtime"
  .effectiveRuntimeRealization.interfaces.uplink0.routes as $routes
  | [($routes.ipv4[]?, $routes.ipv6[]?)
      | select(.intent.kind == "uplink-learned-reachability")] as $learned
  | ($learned | length == 2)
    and all($learned[];
      (.intent.source == "explicit-uplink")
      and (.intent.routeSource == "explicit-uplink")
      and (.intent.sourcePeerOrProvider == "wan")
      and (.intent.routePurpose == "provider-prefix")
      and (.intent.maximumScope == "provider")
      and (.intent.rejectionBehavior == "reject")
      and (.intent.routeAvailabilityOnly == true)
      and (.intent.policyAuthority == false)
    )
' "${output_json}" >/dev/null || {
  echo "FAIL FS-520 CPM runtime route import explanation normalization" >&2
  jq '.control_plane_model.data.acme.ams.runtimeTargets."core-runtime".effectiveRuntimeRealization.interfaces.uplink0.routes' "${output_json}" >&2
  exit 1
}

echo "PASS FS-520 CPM runtime route import explanation normalization"
