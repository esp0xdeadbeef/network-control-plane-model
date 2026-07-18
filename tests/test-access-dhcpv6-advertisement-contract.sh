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
          dhcpv6 = {
            tenant-client = {
              id = "client";
              subnet = "fd42:dead:beef:20::/64";
              pool = {
                start = "fd42:dead:beef:20::100";
                end = "fd42:dead:beef:20::1ff";
              };
              serverAddress = "router-self";
              dnsServers = [ "router-self" ];
              domain = "lan.";
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
    dhcpv6 = builtins.head target.advertisements.dhcpv6;
    leaseState = builtins.head target.stateContracts.persistence.dhcpv6Leases;
    leaseRecord = builtins.head target.stateContracts.operationalRecords.dhcpv6Leases;
  in
    dhcpv6.interface == "tenant-client"
    && dhcpv6.bindInterface == "tenant-client"
    && dhcpv6.tenant == "client"
    && dhcpv6.subnet == "fd42:dead:beef:20::/64"
    && dhcpv6.pool == "fd42:dead:beef:20::100 - fd42:dead:beef:20::1ff"
    && dhcpv6.serverAddress == "fd42:dead:beef:20:0:0:0:1"
    && dhcpv6.dnsServers == [ "fd42:dead:beef:20:0:0:0:1" ]
    && leaseState.service == "dhcpv6"
    && leaseState.kind == "lease-state"
    && leaseState.interface == "tenant-client"
    && leaseState.tenant == "client"
    && leaseRecord.service == "dhcpv6"
' | grep -qx true; then
  echo "FAIL access-dhcpv6-advertisement-contract: CPM did not preserve explicit DHCPv6 advertisement/state contracts" >&2
  exit 1
fi

echo "PASS access-dhcpv6-advertisement-contract"
