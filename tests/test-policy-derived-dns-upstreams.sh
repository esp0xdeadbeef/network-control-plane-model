#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

input_fixture="${repo_root}/fixtures/passing/default-egress-reachability/input.nix"
inventory_fixture="${repo_root}/fixtures/passing/default-egress-reachability/inventory.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cat > "${tmp_dir}/input.nix" <<EOF
let
  base = import ${input_fixture};
in
base
// {
  enterprise =
    base.enterprise
    // {
      acme =
        base.enterprise.acme
        // {
          site =
            base.enterprise.acme.site
            // {
              ams =
                base.enterprise.acme.site.ams
                // {
                  communicationContract = {
                    services = [
                      {
                        name = "site-dns";
                        trafficType = "dns";
                        providers = [ "dns-mgmt" ];
                      }
                    ];

                    allowedRelations =
                      (base.enterprise.acme.site.ams.communicationContract.allowedRelations or [ ])
                      ++ [
                        {
                          from = {
                            kind = "tenant";
                            name = "tenant-a";
                          };
                          to = {
                            kind = "service";
                            name = "site-dns";
                          };
                          trafficType = "dns";
                          action = "allow";
                        }
                      ];
                  };

                  policy =
                    base.enterprise.acme.site.ams.policy
                    // {
                      interfaceTags =
                        base.enterprise.acme.site.ams.policy.interfaceTags
                        // {
                          site-dns = "site-dns";
                        };
                    };
                };
            };
        };
    };
}
EOF

cat > "${tmp_dir}/inventory.nix" <<EOF
let
  base = import ${inventory_fixture};
in
base
// {
  endpoints =
    (base.endpoints or { })
    // {
      dns-mgmt = {
        ipv4 = [ "10.20.10.10" ];
        ipv6 = [ "fd00:10::10" ];
      };
    };

  realization =
    base.realization
    // {
      nodes =
        base.realization.nodes
        // {
          access-runtime =
            base.realization.nodes.access-runtime
            // {
              services.dns = {
                listen = [
                  "10.20.0.1"
                  "fd00:20::1"
                ];
                allowFrom = [
                  "10.20.0.0/24"
                  "fd00:20::/64"
                ];
                forwarders = [
                  "1.1.1.1"
                  "2606:4700:4700::1111"
                ];
              };
            };
        };
    };
}
EOF

output_json="${tmp_dir}/output.json"

nix eval \
  --impure \
  --json \
  --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      builder = flake.lib.${system}.build;
      input = import ${tmp_dir}/input.nix;
      inventory = import ${tmp_dir}/inventory.nix;
    in
      builder { inherit input inventory; }
  " > "${output_json}"

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.acme.ams;
    access = site.runtimeTargets.access-runtime;
    dns = access.services.dns;
    forwarders = dns.forwarders or [ ];
  in
    builtins.elem "10.20.10.10" forwarders
    && builtins.elem "fd00:10::10" forwarders
    && builtins.elem "1.1.1.1" forwarders
    && builtins.elem "2606:4700:4700::1111" forwarders
    && dns.listen == [ "10.20.0.1" "fd00:20::1" ]
    && dns.allowFrom == [ "10.20.0.0/24" "fd00:20::/64" ]
    && !(site.runtimeTargets.policy-runtime ? services)
    && !(site.runtimeTargets.upstream-runtime ? services)
    && !(site.runtimeTargets.core-runtime ? services)
' >/dev/null || {
  echo "FAIL policy-derived-dns-upstreams" >&2
  exit 1
}

echo "PASS policy-derived-dns-upstreams"
