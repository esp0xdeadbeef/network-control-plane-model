#!/usr/bin/env bash
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan-uplink-static-egress"
intent_path="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

[[ -f "${intent_path}" ]] || {
  echo "missing intent fixture: ${intent_path}" >&2
  exit 1
}

[[ -f "${inventory_source}" ]] || {
  echo "missing inventory fixture: ${inventory_source}" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

inventory_path="${tmp_dir}/inventory.nix"
cat > "${inventory_path}" <<EOF
let
  base = import ${inventory_source};
  nodeName = "esp0xdeadbeef-site-a-s-router-access-client";
  node = base.realization.nodes.\${nodeName};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      \${nodeName} = node // {
        advertisements = node.advertisements // {
          ipv6Ra = {
            tenant-client = node.advertisements.ipv6Ra.tenant-client // {
              managed = true;
              otherConfig = true;
              onLink = false;
              autonomous = false;
            };
          };
        };
      };
    };
  };
}
EOF

output_json="${tmp_dir}/out.json"
nix eval --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
    out = flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    };
  in
    out
' > "${output_json}"

if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    target = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    ra = builtins.head target.advertisements.ipv6Ra;
  in
    ra.interface == "tenant-client"
    && ra.bindInterface == "tenant-client"
    && ra.tenant == "client"
    && ra.prefixes == [ "fd42:dead:beef:20::/64" ]
    && ra.rdnss == [ "fd42:dead:beef:20:0:0:0:1" ]
    && ra.managed == true
    && ra.otherConfig == true
    && ra.onLink == false
    && ra.autonomous == false
' | grep -qx true; then
  echo "FAIL access-ipv6-ra-slaac-flags-contract: CPM did not preserve explicit IPv6 RA/SLAAC flags" >&2
  exit 1
fi

echo "PASS access-ipv6-ra-slaac-flags-contract"
