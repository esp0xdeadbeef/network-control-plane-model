#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-MDNS-SERVICE-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

input_fixture="${repo_root}/fixtures/passing/default-egress-reachability/input.nix"
inventory_fixture="${repo_root}/fixtures/passing/default-egress-reachability/inventory.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cat > "${tmp_dir}/input.nix" <<EOF
import ${input_fixture}
EOF

cat > "${tmp_dir}/inventory.nix" <<EOF
let
  base = import ${inventory_fixture};
in
base
// {
  realization =
    base.realization
    // {
      nodes =
        base.realization.nodes
        // {
          access-runtime =
            base.realization.nodes.access-runtime
            // {
              services.mdns = {
                reflector = true;
                discoveryPolicy.relationships = [
                  {
                    requesterScope = "tenant-a";
                    responderScope = "tenant-b";
                    advertisedService = "printer-01";
                    serviceType = "_ipp._tcp";
                    discoveryProtocol = "mdns";
                    direction = "requester-to-responder";
                    boundary = "reflector";
                    allowedAdvertisementData = {
                      hostName = "printer-01.local";
                      addresses = [ "192.0.2.50" ];
                    };
                  }
                ];
                publish = {
                  enable = false;
                  addresses = false;
                };
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
    mdns = data.control_plane_model.data.acme.ams.runtimeTargets.access-runtime.services.mdns;
  in
    mdns.reflector
    && mdns.allowInterfaces == [ "tenant-a" "tenant-b" ]
    && mdns.discoveryPolicy.defaultDecision == "deny-unmodeled-visibility"
    && mdns.discoveryPolicy.relationships == mdns.discoveryRelationships
    && (builtins.head mdns.discoveryRelationships).requesterScope == "tenant-a"
    && (builtins.head mdns.discoveryRelationships).responderScope == "tenant-b"
    && (builtins.head mdns.discoveryRelationships).allowedAdvertisementData.hostName == "printer-01.local"
    && !(mdns.publish.enable or true)
    && !(mdns.publish.addresses or true)
' >/dev/null || {
  echo "FAIL mdns-service" >&2
  exit 1
}

echo "PASS mdns-service"
