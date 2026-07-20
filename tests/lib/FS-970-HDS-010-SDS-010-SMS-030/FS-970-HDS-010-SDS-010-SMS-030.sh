#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
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

duplicate_service_target_inventory="${tmp_dir}/inventory-duplicate-service-target.nix"
write_inventory "${duplicate_service_target_inventory}" '[
  {
    name = "client-fixed";
    hostname = "client-fixed-a";
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
  {
    name = "client-fixed";
    hostname = "client-fixed-b";
    mac = "02:10:20:00:00:11";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 11;
    ipv6.hostOffset = 17;
  }
]' "${valid_dhcpv6}"

if compile_inventory "${duplicate_service_target_inventory}" >"${tmp_dir}/duplicate-service-target.out" 2>"${tmp_dir}/duplicate-service-target.err"; then
  echo "FAIL static-reservation-duplicate-service-target-rejection: duplicate reservation service target was accepted" >&2
  exit 1
fi
grep -F "duplicate reservation id in the same service target" "${tmp_dir}/duplicate-service-target.err" >/dev/null || {
  echo "FAIL static-reservation-duplicate-service-target-rejection: duplicate service target diagnostic was not concise" >&2
  cat "${tmp_dir}/duplicate-service-target.err" >&2
  exit 1
}

echo "PASS static-reservation-duplicate-service-target-rejection"
