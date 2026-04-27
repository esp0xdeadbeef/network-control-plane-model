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
          core-runtime =
            base.realization.nodes.core-runtime
            // {
              services.dns = {
                listen = [
                  "10.20.10.10"
                  "fd00:10::10"
                ];
                allowFrom = [
                  "10.20.10.0/24"
                  "fd00:10::/64"
                ];
                forwarders = [
                  "1.1.1.1"
                  "2606:4700:4700::1111"
                ];
              };
            };

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

          globex-nyc-access-runtime =
            base.realization.nodes.globex-nyc-access-runtime
            // {
              services.dns = {
                listen = [
                  "10.30.0.1"
                  "fd00:30::1"
                ];
                allowFrom = [
                  "10.30.0.0/24"
                  "fd00:30::/64"
                ];
                forwarders = [
                  "10.20.10.10"
                  "fd00:10::10"
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
    core = site.runtimeTargets.core-runtime;
    dns = access.services.dns;
    providerDns = core.services.dns;
    serviceDefs = site.services or [ ];
    siteDns =
      builtins.head (
        builtins.filter
          (service: builtins.isAttrs service && (service.name or null) == "site-dns")
          serviceDefs
      );
    forwarders = dns.forwarders or [ ];
    providerForwarders = providerDns.forwarders or [ ];
    providerAllowFrom = providerDns.allowFrom or [ ];
  in
    builtins.elem "10.20.10.10" forwarders
    && builtins.elem "fd00:10::10" forwarders
    && builtins.elem "1.1.1.1" forwarders
    && builtins.elem "2606:4700:4700::1111" forwarders
    && dns.listen == [ "10.20.0.1" "fd00:20::1" ]
    && dns.allowFrom == [ "10.20.0.0/24" "fd00:20::/64" ]
    && providerForwarders == [ "1.1.1.1" "2606:4700:4700::1111" ]
    && builtins.elem "10.20.10.0/24" providerAllowFrom
    && builtins.elem "fd00:10::/64" providerAllowFrom
    && builtins.elem "10.20.0.0/24" providerAllowFrom
    && builtins.elem "fd00:20::/64" providerAllowFrom
    && builtins.elem "169.254.10.0/31" providerAllowFrom
    && builtins.elem "fd00:10::0/127" providerAllowFrom
    && builtins.elem "10.30.0.0/24" providerAllowFrom
    && builtins.elem "fd00:30::/64" providerAllowFrom
    && builtins.elem "169.254.20.0/31" providerAllowFrom
    && builtins.elem "fd00:20::0/127" providerAllowFrom
    && builtins.elem "mgmt" (siteDns.providerTenants or [ ])
    && !(site.runtimeTargets.policy-runtime ? services)
    && !(site.runtimeTargets.upstream-runtime ? services)
' >/dev/null || {
  echo "FAIL policy-derived-dns-upstreams" >&2
  exit 1
}

echo "PASS policy-derived-dns-upstreams"
