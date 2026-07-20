#!/usr/bin/env bash
# GAMP-ID: FS-860-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan"
intent_path="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
cp "${inventory_source}" "${tmp_dir}/base.nix"

write_inventory() {
  local output_path="$1"
  local dhcp4_lease_path="$2"
  local dhcpv6_lease_path="$3"
  cat >"${output_path}" <<EOF
let
  base = import ./base.nix;
  nodeName = "esp0xdeadbeef-site-a-s-router-access-client";
  node = base.realization.nodes.\${nodeName};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      \${nodeName} = node // {
        statePolicy.persistence = {
          required = true;
          root = "/persist/network/state";
          durabilityClass = "restart-persistent";
        };
        advertisements = node.advertisements // {
          dhcp4 = node.advertisements.dhcp4 // {
            tenant-client = node.advertisements.dhcp4.tenant-client // {
              leaseState.path = "${dhcp4_lease_path}";
            };
          };
          dhcpv6.tenant-client = {
            id = "client";
            subnet = "fd42:dead:beef:20::/64";
            pool = {
              start = "fd42:dead:beef:20::100";
              end = "fd42:dead:beef:20::1ff";
            };
            serverAddress = "router-self";
            dnsServers = [ "router-self" ];
            domain = "lan.";
            leaseState.path = "${dhcpv6_lease_path}";
          };
        };
      };
    };
  };
}
EOF
}

compile_inventory() {
  local inventory_path="$1"
  nix eval --impure --json --expr '
    let
      flake = builtins.getFlake "path:'"${repo_root}"'";
    in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
  '
}

positive_inventory="${tmp_dir}/positive.nix"
write_inventory \
  "${positive_inventory}" \
  "/var/lib/kea/client.leases" \
  "/var/lib/kea/client-v6.leases"
compile_inventory "${positive_inventory}" >"${tmp_dir}/positive.json"

OUTPUT_JSON="${tmp_dir}/positive.json" nix eval --impure --expr '
  let
    output = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    target = output.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    dhcp4 = builtins.head target.advertisements.dhcp4;
    dhcpv6 = builtins.head target.advertisements.dhcpv6;
    state4 = builtins.head target.stateContracts.persistence.dhcp4Leases;
    state6 = builtins.head target.stateContracts.persistence.dhcpv6Leases;
  in
  dhcp4.leaseState.path == "/var/lib/kea/client.leases"
  && state4.path == dhcp4.leaseState.path
  && dhcpv6.leaseState.path == "/var/lib/kea/client-v6.leases"
  && state6.path == dhcpv6.leaseState.path
' | grep -qx true

negative_inventory="${tmp_dir}/negative-empty-path.nix"
write_inventory "${negative_inventory}" "" "/var/lib/kea/client-v6.leases"
if compile_inventory "${negative_inventory}" >"${tmp_dir}/negative.out" 2>"${tmp_dir}/negative.err"; then
  echo "FAIL FS-860 explicit DHCP lease-state path: empty path was accepted" >&2
  exit 1
fi
rg -F 'advertisements.dhcp4.tenant-client.leaseState.path' "${tmp_dir}/negative.err" >/dev/null

echo "PASS FS-860 explicit DHCP and DHCPv6 lease-state paths"
