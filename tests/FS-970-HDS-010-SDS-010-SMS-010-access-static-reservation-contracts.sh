#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-010-SMS-010
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

valid_inventory="${tmp_dir}/inventory-valid.nix"
write_inventory "${valid_inventory}" '[
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
    ipv6.hostOffset = 10;
  }
  {
    name = "client-fixed-11";
    hostname = "client-fixed-11";
    mac = "02:10:20:00:00:11";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 11;
    ipv6.hostOffset = 11;
  }
]' '[
  {
    name = "client-fixed-10";
    hostname = "client-fixed-10";
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "dhcpv6-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 10;
  }
  {
    name = "client-fixed-11";
    hostname = "client-fixed-11";
    mac = "02:10:20:00:00:11";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "dhcpv6-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 11;
    ipv6.hostOffset = 11;
  }
]'

output_json="${tmp_dir}/out.json"
nix eval --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
    out = flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${valid_inventory}"'";
    };
  in
    out
' >"${output_json}"

if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    target = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    dhcp4 = builtins.head target.advertisements.dhcp4;
    dhcpv6 = builtins.head target.advertisements.dhcpv6;
    first4 = builtins.elemAt dhcp4.reservations 0;
    second4 = builtins.elemAt dhcp4.reservations 1;
    first6 = builtins.elemAt dhcpv6.reservations 0;
    second6 = builtins.elemAt dhcpv6.reservations 1;
  in
    first4.mac == "02:10:20:00:00:10"
    && first4.hostOffset == 10
    && first4.address == "10.20.20.10"
    && first4.cidr == "10.20.20.10/32"
    && first4.identitySource.classifier == "FS-720-HDS-010-SDS-030-SMS-010"
    && first4.identitySource.accepted == true
    && first4.identitySource.purpose == "static-dhcp-reservation"
    && second4.address == "10.20.20.11"
    && first6.hostOffset == 16
    && first6.address == "fd42:dead:beef:20:0:0:0:10"
    && first6.cidr == "fd42:dead:beef:20:0:0:0:10/128"
    && first6.identitySource.classifier == "FS-720-HDS-010-SDS-030-SMS-010"
    && first6.identitySource.accepted == true
    && first6.identitySource.purpose == "dhcpv6-reservation"
    && second6.address == "fd42:dead:beef:20:0:0:0:11"
' | grep -qx true; then
  echo "FAIL access-static-reservation-contracts: CPM did not resolve inventory reservations from host offsets" >&2
  exit 1
fi

duplicate_mac_inventory="${tmp_dir}/inventory-duplicate-mac.nix"
write_inventory "${duplicate_mac_inventory}" '[
  { mac = "02:10:20:00:00:10"; macSource = { accepted = true; disposable = true; purpose = "static-dhcp-reservation"; sourceClass = "public-synthetic-lab"; }; ipv4.hostOffset = 10; ipv6.hostOffset = 10; }
  { mac = "02:10:20:00:00:10"; macSource = { accepted = true; disposable = true; purpose = "static-dhcp-reservation"; sourceClass = "public-synthetic-lab"; }; ipv4.hostOffset = 11; ipv6.hostOffset = 11; }
]' '[
  { mac = "02:10:20:00:00:10"; macSource = { accepted = true; disposable = true; purpose = "dhcpv6-reservation"; sourceClass = "public-synthetic-lab"; }; ipv4.hostOffset = 10; ipv6.hostOffset = 10; }
  { mac = "02:10:20:00:00:10"; macSource = { accepted = true; disposable = true; purpose = "dhcpv6-reservation"; sourceClass = "public-synthetic-lab"; }; ipv4.hostOffset = 11; ipv6.hostOffset = 11; }
]'

if nix eval --impure --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
    out = flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${duplicate_mac_inventory}"'";
    };
  in
    builtins.deepSeq out true
' >"${tmp_dir}/duplicate-mac.out" 2>"${tmp_dir}/duplicate-mac.err"; then
  echo "FAIL access-static-reservation-contracts: duplicate MAC was accepted" >&2
  exit 1
fi
grep -F "duplicate MAC address in the same network" "${tmp_dir}/duplicate-mac.err" >/dev/null || {
  echo "FAIL access-static-reservation-contracts: duplicate MAC diagnostic was not concise" >&2
  cat "${tmp_dir}/duplicate-mac.err" >&2
  exit 1
}

duplicate_offset_inventory="${tmp_dir}/inventory-duplicate-offset.nix"
write_inventory "${duplicate_offset_inventory}" '[
  { mac = "02:10:20:00:00:10"; macSource = { accepted = true; disposable = true; purpose = "static-dhcp-reservation"; sourceClass = "public-synthetic-lab"; }; ipv4.hostOffset = 10; ipv6.hostOffset = 10; }
  { mac = "02:10:20:00:00:11"; macSource = { accepted = true; disposable = true; purpose = "static-dhcp-reservation"; sourceClass = "public-synthetic-lab"; }; ipv4.hostOffset = 10; ipv6.hostOffset = 11; }
]' '[
  { mac = "02:10:20:00:00:10"; macSource = { accepted = true; disposable = true; purpose = "dhcpv6-reservation"; sourceClass = "public-synthetic-lab"; }; ipv4.hostOffset = 10; ipv6.hostOffset = 10; }
  { mac = "02:10:20:00:00:11"; macSource = { accepted = true; disposable = true; purpose = "dhcpv6-reservation"; sourceClass = "public-synthetic-lab"; }; ipv4.hostOffset = 10; ipv6.hostOffset = 11; }
]'

if nix eval --impure --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
    out = flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${duplicate_offset_inventory}"'";
    };
  in
    builtins.deepSeq out true
' >"${tmp_dir}/duplicate-offset.out" 2>"${tmp_dir}/duplicate-offset.err"; then
  echo "FAIL access-static-reservation-contracts: duplicate host offset was accepted" >&2
  exit 1
fi
grep -F "duplicate ipv4.hostOffset in the same network" "${tmp_dir}/duplicate-offset.err" >/dev/null || {
  echo "FAIL access-static-reservation-contracts: duplicate offset diagnostic was not concise" >&2
  cat "${tmp_dir}/duplicate-offset.err" >&2
  exit 1
}

echo "PASS access-static-reservation-contracts"
