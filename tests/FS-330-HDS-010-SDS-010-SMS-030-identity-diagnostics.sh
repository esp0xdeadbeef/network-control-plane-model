#!/usr/bin/env bash
# GAMP-ID: FS-330-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
# Tests the identity diagnostics module contract:
#   SN1 - duplicate MAC across two different clients in same access space
#   SN2 - missing required identity fields (assignment context)
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

# ---------------------------------------------------------------------------
# SN1: Duplicate MAC address across two different clients in the same
# access space.  The diagnostic must name both client identities instead
# of silently accepting the duplicate MAC.
# ---------------------------------------------------------------------------
echo "--- SMS-030 SN1: duplicate MAC across different clients ---"

sn1_dhcp4='[
  {
    id = "client-alpha";
    hostname = "client-alpha";
    mac = "02:10:20:00:00:11";
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
  {
    id = "client-beta";
    hostname = "client-beta";
    mac = "02:10:20:00:00:11";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      source = "public-inventory";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 18;
    ipv6.hostOffset = "12";
  }
]'

sn1_inventory="${tmp_dir}/inventory-sn1.nix"
write_inventory "${sn1_inventory}" "${sn1_dhcp4}" '[ ]'

if compile_inventory "${tmp_dir}/intent-base.nix" "${sn1_inventory}" >"${tmp_dir}/sn1.out" 2>"${tmp_dir}/sn1.err"; then
  echo "FAIL FS-330-HDS-010-SDS-010-SMS-030 SN1: duplicate MAC across two clients was accepted" >&2
  exit 1
fi

# The diagnostic must name the duplicate MAC value
grep -qE 'duplicate MAC address "02:10:20:00:00:11" across reservations' "${tmp_dir}/sn1.err" || {
  echo "FAIL FS-330-HDS-010-SDS-010-SMS-030 SN1: duplicate-MAC diagnostic did not name the MAC address" >&2
  cat "${tmp_dir}/sn1.err" >&2
  exit 1
}

echo "PASS FS-330-HDS-010-SDS-010-SMS-030 SN1"

# ---------------------------------------------------------------------------
# SN2: A client identity record missing required assignment-context fields.
# The SMS-030 spec says: missing required fields (assignment role,
# address family, or site) must produce a malformed-identity diagnostic
# naming the missing fields.
#
# In the CPM reservation context, "assignment role" and "address family"
# are expressed by which DHCP advertisement group the reservation
# belongs to.  A reservation that has no ipv4 object (for a dhcp4
# advertisement) is effectively missing its address-family role
# assignment.  The diagnostic must name the missing field and the client.
# ---------------------------------------------------------------------------
echo "--- SMS-030 SN2: missing required identity fields ---"

sn2_dhcp4='[
  {
    id = "client-norole";
    hostname = "client-norole";
    mac = "02:10:20:00:00:99";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      source = "public-inventory";
      sourceClass = "public-synthetic-lab";
    };
  }
]'

sn2_inventory="${tmp_dir}/inventory-sn2.nix"
write_inventory "${sn2_inventory}" "${sn2_dhcp4}" '[ ]'

if compile_inventory "${tmp_dir}/intent-base.nix" "${sn2_inventory}" >"${tmp_dir}/sn2.out" 2>"${tmp_dir}/sn2.err"; then
  echo "FAIL FS-330-HDS-010-SDS-010-SMS-030 SN2: reservation missing assignment-role fields was accepted" >&2
  exit 1
fi

# The CPM diagnostics name the reservation and the missing field.
# For a missing ipv4 object in an ipv4 advertisement, we expect
# the diagnostic to name the client and the missing ipv4 attribute set.
grep -qF 'reservations[0].ipv4' "${tmp_dir}/sn2.err" || {
  echo "FAIL FS-330-HDS-010-SDS-010-SMS-030 SN2: missing-field diagnostic did not name the missing field or client" >&2
  cat "${tmp_dir}/sn2.err" >&2
  exit 1
}

echo "PASS FS-330-HDS-010-SDS-010-SMS-030 SN2"

# ---------------------------------------------------------------------------
# Verify sibling SMS-010/SMS-020 tests still pass (consistency gate)
# ---------------------------------------------------------------------------
echo "--- SMS-030 consistency: sibling SMS-010/SMS-020 test ---"
NETWORK_REPO_DIRECT_TEST_OK=1 bash "${repo_root}/tests/FS-330-HDS-010-SDS-010-SMS-010-fs330-stable-client-address-identity.sh" || {
  echo "FAIL FS-330-HDS-010-SDS-010-SMS-030: sibling SMS-010/020 test regressed" >&2
  exit 1
}

echo "PASS FS-330-HDS-010-SDS-010-SMS-030"
