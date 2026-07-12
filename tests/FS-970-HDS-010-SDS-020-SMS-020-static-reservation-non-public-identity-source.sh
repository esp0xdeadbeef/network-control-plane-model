#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-020-SMS-020
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

valid_inventory="${tmp_dir}/inventory-valid.nix"
write_inventory "${valid_inventory}" '[
  {
    id = "protected-dhcp4";
    hostname = "client-fixed-10";
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = true;
      disposable = false;
      purpose = "static-dhcp-reservation";
      sourceClass = "protected";
      source = "protected-inventory";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]' '[
  {
    id = "protected-dhcpv6";
    hostname = "client-fixed-16";
    mac = "02:10:20:00:00:16";
    macSource = {
      accepted = true;
      disposable = false;
      purpose = "dhcpv6-reservation";
      sourceClass = "protected";
      secretRef = "sops://inventory/reservations/client-fixed-16";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]'

output_json="${tmp_dir}/out.json"
compile_inventory "${valid_inventory}" >"${output_json}"

if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    target = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    dhcp4 = builtins.head target.advertisements.dhcp4;
    dhcpv6 = builtins.head target.advertisements.dhcpv6;
    reservation4 = builtins.elemAt dhcp4.reservations 0;
    reservation6 = builtins.elemAt dhcpv6.reservations 0;
  in
    reservation4.id == "protected-dhcp4"
    && reservation4.identitySource.sourceClass == "protected"
    && reservation4.identitySource.source == "protected-inventory"
    && reservation6.id == "protected-dhcpv6"
    && reservation6.identitySource.sourceClass == "protected"
    && reservation6.identitySource.secretRef == "sops://inventory/reservations/client-fixed-16"
' | grep -qx true; then
  echo "FAIL static-reservation-non-public-identity-source: CPM did not preserve protected reservation identity source records" >&2
  exit 1
fi

missing_protected_source_inventory="${tmp_dir}/inventory-missing-protected-source.nix"
write_inventory "${missing_protected_source_inventory}" '[
  {
    id = "missing-protected-source";
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = true;
      disposable = false;
      purpose = "static-dhcp-reservation";
      sourceClass = "protected";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]' '[ ]'

if compile_inventory "${missing_protected_source_inventory}" >"${tmp_dir}/missing-protected-source.out" 2>"${tmp_dir}/missing-protected-source.err"; then
  echo "FAIL static-reservation-non-public-identity-source: protected reservation identity without protected source material was accepted" >&2
  exit 1
fi
grep -F "reservation requirement 'missing-protected-source' requires protected inventory source='protected-inventory', secretRef, or sourceFile for non-public reservation identity" \
  "${tmp_dir}/missing-protected-source.err" >/dev/null || {
    echo "FAIL static-reservation-non-public-identity-source: missing protected-source diagnostic was not concise" >&2
    cat "${tmp_dir}/missing-protected-source.err" >&2
    exit 1
  }

public_leak_inventory="${tmp_dir}/inventory-public-leak.nix"
write_inventory "${public_leak_inventory}" '[
  {
    id = "public-leak";
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = true;
      disposable = false;
      purpose = "static-dhcp-reservation";
      sourceClass = "protected";
      source = "public-inventory";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]' '[ ]'

if compile_inventory "${public_leak_inventory}" >"${tmp_dir}/public-leak.out" 2>"${tmp_dir}/public-leak.err"; then
  echo "FAIL static-reservation-non-public-identity-source: protected reservation identity emitted as public inventory was accepted" >&2
  exit 1
fi
grep -F "reservation requirement 'public-leak' must not emit protected reservation identity material as public inventory" \
  "${tmp_dir}/public-leak.err" >/dev/null || {
    echo "FAIL static-reservation-non-public-identity-source: protected-source leak diagnostic was not concise" >&2
    cat "${tmp_dir}/public-leak.err" >&2
    exit 1
  }

echo "PASS static-reservation-non-public-identity-source"
