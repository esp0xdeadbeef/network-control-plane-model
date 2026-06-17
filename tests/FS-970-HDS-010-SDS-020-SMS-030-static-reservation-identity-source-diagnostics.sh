#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-020-SMS-030
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

example_root="$(flake_input_path network-labs)/examples/single-wan"
intent_path="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cp "${inventory_source}" "${tmp_dir}/base.nix"

write_inventory() {
  local path="$1"
  local dhcp4_reservations="$2"
  local dhcpv6_reservations="$3"
  cat >"${path}" <<EOF
let
  base = import ./base.nix;
  nodeName = "esp0xdeadbeef-site-a-s-router-access-client";
  node = base.realization.nodes.\${nodeName};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      \${nodeName} = node // {
        advertisements = node.advertisements // {
          dhcp4 = {
            tenant-client = {
              id = "client";
              subnet = "10.20.20.0/24";
              pool = {
                start = "10.20.20.100";
                end = "10.20.20.199";
              };
              router = "router-self";
              dnsServers = [ "router-self" ];
              domain = "lan.";
              reservations = ${dhcp4_reservations};
            };
          };
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
              reservations = ${dhcpv6_reservations};
            };
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
      flake = builtins.getFlake "'"path:${repo_root}"'";
      out = flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${intent_path}"'";
        inventoryPath = "'"${inventory_path}"'";
      };
    in
      out
  '
}

missing_public_source_inventory="${tmp_dir}/inventory-missing-public-source.nix"
write_inventory "${missing_public_source_inventory}" '[
  {
    id = "missing-public-source";
    mac = "02:10:20:00:00:10";
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]' '[ ]'

if compile_inventory "${missing_public_source_inventory}" >"${tmp_dir}/missing-public-source.out" 2>"${tmp_dir}/missing-public-source.err"; then
  echo "FAIL static-reservation-identity-source-diagnostics: reservation without public identity source material was accepted" >&2
  exit 1
fi
grep -F "reservation requirement 'missing-public-source' requires accepted MAC source classification from FS-720-HDS-010-SDS-030-SMS-010" \
  "${tmp_dir}/missing-public-source.err" >/dev/null || {
    echo "FAIL static-reservation-identity-source-diagnostics: missing public-source diagnostic did not name the reservation requirement" >&2
    cat "${tmp_dir}/missing-public-source.err" >&2
    exit 1
  }

missing_protected_source_inventory="${tmp_dir}/inventory-missing-protected-source.nix"
write_inventory "${missing_protected_source_inventory}" '[ ]' '[
  {
    id = "missing-protected-source";
    mac = "02:10:20:00:00:16";
    macSource = {
      accepted = true;
      disposable = false;
      purpose = "dhcpv6-reservation";
      sourceClass = "protected";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]'

if compile_inventory "${missing_protected_source_inventory}" >"${tmp_dir}/missing-protected-source.out" 2>"${tmp_dir}/missing-protected-source.err"; then
  echo "FAIL static-reservation-identity-source-diagnostics: reservation without protected identity source material was accepted" >&2
  exit 1
fi
grep -F "reservation requirement 'missing-protected-source' requires protected inventory source='protected-inventory' or secretRef for non-public reservation identity" \
  "${tmp_dir}/missing-protected-source.err" >/dev/null || {
    echo "FAIL static-reservation-identity-source-diagnostics: missing protected-source diagnostic did not name the reservation requirement" >&2
    cat "${tmp_dir}/missing-protected-source.err" >&2
    exit 1
  }

echo "PASS static-reservation-identity-source-diagnostics"
