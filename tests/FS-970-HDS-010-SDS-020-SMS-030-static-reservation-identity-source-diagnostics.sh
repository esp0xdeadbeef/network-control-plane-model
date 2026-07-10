#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-020-SMS-030
# GAMP-SCOPE: software-module-test
# Tests the reservation identity source diagnostics module contract:
#   SN1 - missing public/protected identity source → diagnostic.reservation-identity-source-missing
#   SN2 - missing-identity diagnostic lacks reservation handle → diagnostic.reservation-identity-diagnostic-unscoped
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

# ---------------------------------------------------------------------------
# SN1 — Negative case 1: Reservation lacks all identity sources.
# Construct a required static reservation with no MAC address, DHCPv6
# identifier, equivalent public identity, protected inventory reference,
# or protected secret reference. The module shall reject it with
# diagnostic.reservation-identity-source-missing, naming the
# reservation requirement.
# ---------------------------------------------------------------------------
echo "--- SMS-030 SN1a: missing public identity source ---"

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
  echo "FAIL FS-970-HDS-010-SDS-020-SMS-030 SN1a: reservation without public identity source material was accepted" >&2
  exit 1
fi
grep -F "diagnostic.reservation-identity-source-missing" \
  "${tmp_dir}/missing-public-source.err" >/dev/null || {
    echo "FAIL FS-970-HDS-010-SDS-020-SMS-030 SN1a: diagnostic.reservation-identity-source-missing not emitted" >&2
    cat "${tmp_dir}/missing-public-source.err" >&2
    exit 1
  }
grep -F "reservation requirement 'missing-public-source'" \
  "${tmp_dir}/missing-public-source.err" >/dev/null || {
    echo "FAIL FS-970-HDS-010-SDS-020-SMS-030 SN1a: diagnostic did not name the reservation requirement" >&2
    cat "${tmp_dir}/missing-public-source.err" >&2
    exit 1
  }

echo "PASS FS-970-HDS-010-SDS-020-SMS-030 SN1a"

echo "--- SMS-030 SN1b: missing protected identity source ---"

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
  echo "FAIL FS-970-HDS-010-SDS-020-SMS-030 SN1b: reservation without protected identity source material was accepted" >&2
  exit 1
fi
grep -F "reservation requirement 'missing-protected-source' requires protected inventory source='protected-inventory' or secretRef" \
  "${tmp_dir}/missing-protected-source.err" >/dev/null || {
    echo "FAIL FS-970-HDS-010-SDS-020-SMS-030 SN1b: missing protected-source diagnostic did not name the reservation requirement" >&2
    cat "${tmp_dir}/missing-protected-source.err" >&2
    exit 1
  }

echo "PASS FS-970-HDS-010-SDS-020-SMS-030 SN1b"

# ---------------------------------------------------------------------------
# SN2 — Negative case 2: Missing-identity diagnostic lacks reservation handle.
# Construct a missing-identity diagnostic that omits the affected served scope,
# reservation handle, or client identity class. The module shall reject it
# with diagnostic.reservation-identity-diagnostic-unscoped.
#
# A reservation with no id, name, hostname, or mac cannot produce a scoped
# diagnostic handle; the module must reject it with the unscoped diagnostic
# instead of emitting a path-only fallback diagnostic.
# ---------------------------------------------------------------------------
echo "--- SMS-030 SN2: missing-identity diagnostic lacks reservation handle ---"

unscoped_inventory="${tmp_dir}/inventory-unscoped-diagnostic.nix"
write_inventory "${unscoped_inventory}" '[
  {
    ipv4.hostOffset = 99;
    ipv6.hostOffset = 99;
  }
]' '[ ]'

if compile_inventory "${unscoped_inventory}" >"${tmp_dir}/unscoped.out" 2>"${tmp_dir}/unscoped.err"; then
  echo "FAIL FS-970-HDS-010-SDS-020-SMS-030 SN2: unscoped reservation without identity was accepted" >&2
  exit 1
fi
grep -F "diagnostic.reservation-identity-diagnostic-unscoped" \
  "${tmp_dir}/unscoped.err" >/dev/null || {
    echo "FAIL FS-970-HDS-010-SDS-020-SMS-030 SN2: diagnostic.reservation-identity-diagnostic-unscoped not emitted" >&2
    cat "${tmp_dir}/unscoped.err" >&2
    exit 1
  }

echo "PASS FS-970-HDS-010-SDS-020-SMS-030 SN2"

# ---------------------------------------------------------------------------
# Consistency: verify no downstream emission from defective input
# Run the sibling SMS-010 test for reservation identity consumption
# ---------------------------------------------------------------------------
echo "--- SMS-030 consistency: sibling SMS-010 test ---"
NETWORK_REPO_DIRECT_TEST_OK=1 bash "${repo_root}/tests/FS-970-HDS-010-SDS-020-SMS-010-static-reservation-classified-identity-consumption.sh" || {
  echo "FAIL FS-970-HDS-010-SDS-020-SMS-030: sibling SMS-010 test regressed" >&2
  exit 1
}

echo "--- SMS-030 consistency: sibling SMS-020 test ---"
NETWORK_REPO_DIRECT_TEST_OK=1 bash "${repo_root}/tests/FS-970-HDS-010-SDS-020-SMS-020-static-reservation-non-public-identity-source.sh" || {
  echo "FAIL FS-970-HDS-010-SDS-020-SMS-030: sibling SMS-020 test regressed" >&2
  exit 1
}

echo "PASS FS-970-HDS-010-SDS-020-SMS-030"
