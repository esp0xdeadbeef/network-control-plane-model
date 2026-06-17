#!/usr/bin/env bash
# GAMP-ID: FS-330-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-330-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-330-HDS-010-SDS-010-SMS-030
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
intent_source="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cp "${inventory_source}" "${tmp_dir}/base.nix"
cp "${intent_source}" "${tmp_dir}/intent-base.nix"
sed \
  -e 's|10.20.20.0/24|10.30.30.0/24|g' \
  -e 's|fd42:dead:beef:20::/64|fd42:dead:beef:30::/64|g' \
  "${intent_source}" >"${tmp_dir}/intent-remap.nix"
sed 's|fd42:dead:beef:20::/64|fd42:dead:beef:20::/112|g' \
  "${intent_source}" >"${tmp_dir}/intent-small-ipv6.nix"

write_inventory() {
  local path="$1"
  local ipv4_subnet="$2"
  local ipv6_subnet="$3"
  local dhcp4_reservations="$4"
  local dhcpv6_reservations="$5"
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
              subnet = "${ipv4_subnet}";
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
              subnet = "${ipv6_subnet}";
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
  local intent_path="$1"
  local inventory_path="$2"
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
    id = "client-one";
    hostname = "client-one";
    mac = "02-10-20-00-00-11";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      source = "public-inventory";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 17;
    ipv6.hostOffset = "11";
  }
]'

valid_dhcpv6='[
  {
    id = "client-one";
    hostname = "client-one";
    mac = "02-10-20-00-00-11";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "dhcpv6-reservation";
      source = "public-inventory";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 17;
    ipv6.hostOffset = "11";
  }
]'

base_inventory="${tmp_dir}/inventory-base.nix"
remap_inventory="${tmp_dir}/inventory-remap.nix"
write_inventory "${base_inventory}" "10.20.20.0/24" "fd42:dead:beef:20::/64" "${valid_dhcp4}" "${valid_dhcpv6}"
write_inventory "${remap_inventory}" "10.30.30.0/24" "fd42:dead:beef:30::/64" "${valid_dhcp4}" "${valid_dhcpv6}"

base_json="${tmp_dir}/base.json"
remap_json="${tmp_dir}/remap.json"
compile_inventory "${tmp_dir}/intent-base.nix" "${base_inventory}" >"${base_json}"
compile_inventory "${tmp_dir}/intent-remap.nix" "${remap_inventory}" >"${remap_json}"

if ! BASE_JSON="${base_json}" REMAP_JSON="${remap_json}" nix eval --impure --expr '
  let
    base = builtins.fromJSON (builtins.readFile (builtins.getEnv "BASE_JSON"));
    remap = builtins.fromJSON (builtins.readFile (builtins.getEnv "REMAP_JSON"));
    targetFor = data:
      data.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    baseTarget = targetFor base;
    remapTarget = targetFor remap;
    base4 = builtins.elemAt (builtins.head baseTarget.advertisements.dhcp4).reservations 0;
    base6 = builtins.elemAt (builtins.head baseTarget.advertisements.dhcpv6).reservations 0;
    remap4 = builtins.elemAt (builtins.head remapTarget.advertisements.dhcp4).reservations 0;
    remap6 = builtins.elemAt (builtins.head remapTarget.advertisements.dhcpv6).reservations 0;
    dhcp4 = builtins.head baseTarget.advertisements.dhcp4;
    dhcpv6 = builtins.head baseTarget.advertisements.dhcpv6;
  in
    dhcp4.interface == "tenant-client"
    && dhcp4.tenant == "client"
    && dhcp4.subnet == "10.20.20.0/24"
    && dhcpv6.interface == "tenant-client"
    && dhcpv6.tenant == "client"
    && dhcpv6.subnet == "fd42:dead:beef:20::/64"
    && base4.id == "client-one"
    && base4.hostname == "client-one"
    && base4.mac == "02:10:20:00:00:11"
    && base4.hostOffset == 17
    && base4.address == "10.20.20.17"
    && base4.cidr == "10.20.20.17/32"
    && base4.source == "inventory-realization"
    && base4.identitySource.classifier == "FS-720-HDS-010-SDS-030-SMS-010"
    && base4.identitySource.accepted == true
    && base4.identitySource.source == "public-inventory"
    && base6.id == "client-one"
    && base6.mac == "02:10:20:00:00:11"
    && base6.hostOffset == 17
    && base6.address == "fd42:dead:beef:20:0:0:0:11"
    && base6.cidr == "fd42:dead:beef:20:0:0:0:11/128"
    && base6.identitySource.purpose == "dhcpv6-reservation"
    && remap4.id == base4.id
    && remap4.mac == base4.mac
    && remap4.hostOffset == base4.hostOffset
    && remap4.address == "10.30.30.17"
    && remap4.cidr == "10.30.30.17/32"
    && remap6.id == base6.id
    && remap6.mac == base6.mac
    && remap6.hostOffset == base6.hostOffset
    && remap6.address == "fd42:dead:beef:30:0:0:0:11"
    && remap6.cidr == "fd42:dead:beef:30:0:0:0:11/128"
' | grep -qx true; then
  echo "FAIL fs330-stable-client-address-identity: CPM did not preserve stable identity or offset remap records" >&2
  exit 1
fi

malformed_mac_inventory="${tmp_dir}/inventory-malformed-mac.nix"
write_inventory "${malformed_mac_inventory}" "10.20.20.0/24" "fd42:dead:beef:20::/64" '[
  {
    id = "client-one";
    mac = "not-a-mac";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 17;
    ipv6.hostOffset = "11";
  }
]' '[ ]'

if compile_inventory "${tmp_dir}/intent-base.nix" "${malformed_mac_inventory}" >"${tmp_dir}/malformed-mac.out" 2>"${tmp_dir}/malformed-mac.err"; then
  echo "FAIL fs330-stable-client-address-identity: malformed MAC was accepted" >&2
  exit 1
fi
grep -F "reservation requirement 'client-one' requires complete MAC address" "${tmp_dir}/malformed-mac.err" >/dev/null || {
  echo "FAIL fs330-stable-client-address-identity: malformed MAC diagnostic did not name the known client identity" >&2
  cat "${tmp_dir}/malformed-mac.err" >&2
  exit 1
}

duplicate_identity_inventory="${tmp_dir}/inventory-duplicate-identity.nix"
write_inventory "${duplicate_identity_inventory}" "10.20.20.0/24" "fd42:dead:beef:20::/64" '[
  {
    id = "client-one";
    mac = "02:10:20:00:00:11";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 17;
    ipv6.hostOffset = "11";
  }
  {
    id = "client-one";
    mac = "02:10:20:00:00:12";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 18;
    ipv6.hostOffset = "12";
  }
]' '[ ]'

if compile_inventory "${tmp_dir}/intent-base.nix" "${duplicate_identity_inventory}" >"${tmp_dir}/duplicate-identity.out" 2>"${tmp_dir}/duplicate-identity.err"; then
  echo "FAIL fs330-stable-client-address-identity: duplicate client identity was accepted" >&2
  exit 1
fi
grep -F "duplicate reservation id in the same service target" "${tmp_dir}/duplicate-identity.err" >/dev/null || {
  echo "FAIL fs330-stable-client-address-identity: duplicate identity diagnostic was not one-to-one" >&2
  cat "${tmp_dir}/duplicate-identity.err" >&2
  exit 1
}

small_ipv6_inventory="${tmp_dir}/inventory-small-ipv6.nix"
write_inventory "${small_ipv6_inventory}" "10.20.20.0/24" "fd42:dead:beef:20::/112" "${valid_dhcp4}" '[
  {
    id = "client-one";
    hostname = "client-one";
    mac = "02-10-20-00-00-11";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "dhcpv6-reservation";
      source = "public-inventory";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 17;
    ipv6.hostOffset = "10000";
  }
]'

if compile_inventory "${tmp_dir}/intent-small-ipv6.nix" "${small_ipv6_inventory}" >"${tmp_dir}/small-ipv6.out" 2>"${tmp_dir}/small-ipv6.err"; then
  echo "FAIL fs330-stable-client-address-identity: preserved offset remap into too-small IPv6 prefix was accepted" >&2
  exit 1
fi
grep -F "IPv6 offset 65536 overflows fd42:dead:beef:20::/112 capacity 65536" "${tmp_dir}/small-ipv6.err" >/dev/null || {
  echo "FAIL fs330-stable-client-address-identity: unusable preserved-offset diagnostic did not name prefix and offset" >&2
  cat "${tmp_dir}/small-ipv6.err" >&2
  exit 1
}

echo "PASS fs330-stable-client-address-identity"
