#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-010-SMS-020
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

valid_dhcp4='[
  {
    name = "client-fixed-10";
    hostname = "client-fixed-10";
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]'

valid_dhcpv6='[
  {
    name = "client-fixed-16";
    hostname = "client-fixed-16";
    mac = "02:10:20:00:00:16";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "dhcpv6-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]'

valid_inventory="${tmp_dir}/inventory-valid.nix"
write_inventory "${valid_inventory}" "${valid_dhcp4}" "${valid_dhcpv6}"

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
    reservation4.hostOffset == 10
    && reservation4.address == "10.20.20.10"
    && reservation4.cidr == "10.20.20.10/32"
    && reservation4.source == "inventory-realization"
    && reservation6.hostOffset == 16
    && reservation6.address == "fd42:dead:beef:20:0:0:0:10"
    && reservation6.cidr == "fd42:dead:beef:20:0:0:0:10/128"
    && reservation6.source == "inventory-realization"
' | grep -qx true; then
  echo "FAIL static-reservation-offset-resolution: CPM did not resolve DHCP/DHCPv6 host offsets into explicit reservation records" >&2
  exit 1
fi

overflow_ipv4_inventory="${tmp_dir}/inventory-overflow-ipv4.nix"
write_inventory "${overflow_ipv4_inventory}" '[
  {
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 256;
    ipv6.hostOffset = 16;
  }
]' "${valid_dhcpv6}"

if compile_inventory "${overflow_ipv4_inventory}" >"${tmp_dir}/overflow-ipv4.out" 2>"${tmp_dir}/overflow-ipv4.err"; then
  echo "FAIL static-reservation-offset-resolution: out-of-prefix IPv4 offset was accepted" >&2
  exit 1
fi
grep -F "IPv4 offset 256 overflows 10.20.20.0/24 capacity 256" "${tmp_dir}/overflow-ipv4.err" >/dev/null || {
  echo "FAIL static-reservation-offset-resolution: IPv4 overflow diagnostic was not concise" >&2
  cat "${tmp_dir}/overflow-ipv4.err" >&2
  exit 1
}

negative_ipv6_inventory="${tmp_dir}/inventory-negative-ipv6.nix"
write_inventory "${negative_ipv6_inventory}" "${valid_dhcp4}" '[
  {
    mac = "02:10:20:00:00:16";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "dhcpv6-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = -1;
  }
]'

if compile_inventory "${negative_ipv6_inventory}" >"${tmp_dir}/negative-ipv6.out" 2>"${tmp_dir}/negative-ipv6.err"; then
  echo "FAIL static-reservation-offset-resolution: invalid IPv6 offset was accepted" >&2
  exit 1
fi
grep -F "IPv6 offset -1 must be non-negative" "${tmp_dir}/negative-ipv6.err" >/dev/null || {
  echo "FAIL static-reservation-offset-resolution: IPv6 offset diagnostic was not concise" >&2
  cat "${tmp_dir}/negative-ipv6.err" >&2
  exit 1
}

missing_family_inventory="${tmp_dir}/inventory-missing-family.nix"
write_inventory "${missing_family_inventory}" '[
  {
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv6.hostOffset = 16;
  }
]' "${valid_dhcpv6}"

if compile_inventory "${missing_family_inventory}" >"${tmp_dir}/missing-family.out" 2>"${tmp_dir}/missing-family.err"; then
  echo "FAIL static-reservation-offset-resolution: reservation without matching IPv4 offset was accepted" >&2
  exit 1
fi
grep -F "reservations[0].ipv4 must be an attribute set" "${tmp_dir}/missing-family.err" >/dev/null || {
  echo "FAIL static-reservation-offset-resolution: missing-family diagnostic was not concise" >&2
  cat "${tmp_dir}/missing-family.err" >&2
  exit 1
}

echo "PASS static-reservation-offset-resolution"
