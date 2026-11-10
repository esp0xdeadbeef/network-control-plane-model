#!/usr/bin/env bash
# GAMP-ID: FS-340-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
#
# IPv4 decimal offset parsing. Exercises the module contract that
# documentation/SMS/FS-340-HDS-010-SDS-010-SMS-010.md defines: the IPv4 host
# offset of a static reservation is parsed only as a decimal host-position
# value inside the modeled subnet, and non-conforming syntax is rejected with
# the named diagnostics rather than silently coerced.
#
# The two seeded negatives are the SMS ones:
#   SN1: offset "0x0A" -> diagnostic.nonDecimalOffset (a hexadecimal offset is
#        not read as decimal 10).
#   SN2: offset 300 in a /24 -> out-of-range rejection, not a wrap/truncation.
# Plus the positive: a decimal-string offset ("10") resolves to the same
# reservation record as the integer 10, so decimal input is not merely tolerated
# as an integer by accident.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
# shellcheck source=tests/lib/direct-test-guard.sh
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq

flake_input_path() {
  local input_name="$1"
  if [[ "${input_name}" == "network-labs" && -n "${NETWORK_LABS_PATH:-}" ]]; then
    realpath "${NETWORK_LABS_PATH}"
    return
  fi
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan"
intent_source="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cp "${inventory_source}" "${tmp_dir}/base.nix"
intent_path="${intent_source}"

# write_inventory <path> <ipv4-hostOffset-nix-expression>
# Only the IPv4 reservation offset is varied; every other reservation field is
# constant so a failure names the offset contract and nothing else.
write_inventory() {
  local path="$1"
  local ipv4_offset="$2"
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
              reservations = [
                {
                  name = "client-fixed";
                  hostname = "client-fixed";
                  mac = "02:10:20:00:00:10";
                  macSource = {
                    accepted = true;
                    disposable = true;
                    purpose = "static-dhcp-reservation";
                    sourceClass = "public-synthetic-lab";
                  };
                  ipv4.hostOffset = ${ipv4_offset};
                }
              ];
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
  nix eval --no-write-lock-file --impure --json --expr '
    let
      flake = builtins.getFlake "'"path:${repo_root}"'";
    in
      flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${intent_path}"'";
        inventoryPath = "'"${inventory_path}"'";
      }
  '
}

# Positive: an integer offset and its decimal-string spelling resolve to the
# same explicit reservation record.
int_ok_inventory="${tmp_dir}/inventory-int.nix"
write_inventory "${int_ok_inventory}" '10'
str_ok_inventory="${tmp_dir}/inventory-str.nix"
write_inventory "${str_ok_inventory}" '"10"'

compile_inventory "${int_ok_inventory}" >"${tmp_dir}/int.out"
compile_inventory "${str_ok_inventory}" >"${tmp_dir}/str.out"

if ! INT_OUT="${tmp_dir}/int.out" STR_OUT="${tmp_dir}/str.out" nix eval --no-write-lock-file --impure --expr '
  let
    read = path: builtins.fromJSON (builtins.readFile path);
    reservation = path:
      let
        data = read path;
        site = data.control_plane_model.data.esp0xdeadbeef."site-a";
        target = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
        dhcp4 = builtins.head target.advertisements.dhcp4;
      in
        builtins.head dhcp4.reservations;
    intReservation = reservation (builtins.getEnv "INT_OUT");
    strReservation = reservation (builtins.getEnv "STR_OUT");
  in
    intReservation.hostOffset == 10
    && intReservation.address == "10.20.20.10"
    && intReservation.cidr == "10.20.20.10/32"
    && strReservation.hostOffset == 10
    && strReservation.address == "10.20.20.10"
    && strReservation.cidr == "10.20.20.10/32"
' | grep -qx true; then
  echo "FAIL ipv4-decimal-offset-parsing: a decimal IPv4 offset did not resolve to the explicit reservation record" >&2
  exit 1
fi

# SN1: a hexadecimal offset string is rejected as non-decimal. It must not be
# quietly read as decimal 10, which would place the client at 10.20.20.10.
hex_inventory="${tmp_dir}/inventory-hex.nix"
write_inventory "${hex_inventory}" '"0x0A"'

if compile_inventory "${hex_inventory}" >"${tmp_dir}/hex.out" 2>"${tmp_dir}/hex.err"; then
  echo "FAIL ipv4-decimal-offset-parsing: a hexadecimal IPv4 offset (\"0x0A\") was accepted instead of rejected as non-decimal" >&2
  exit 1
fi

if ! grep -F "diagnostic.nonDecimalOffset" "${tmp_dir}/hex.err" >/dev/null; then
  echo "FAIL ipv4-decimal-offset-parsing: the hexadecimal offset rejection did not carry diagnostic.nonDecimalOffset" >&2
  cat "${tmp_dir}/hex.err" >&2
  exit 1
fi

if ! grep -F '0x0A' "${tmp_dir}/hex.err" >/dev/null; then
  echo "FAIL ipv4-decimal-offset-parsing: the nonDecimalOffset diagnostic did not name the violating value \"0x0A\"" >&2
  cat "${tmp_dir}/hex.err" >&2
  exit 1
fi

if [[ -s "${tmp_dir}/hex.out" ]]; then
  echo "FAIL ipv4-decimal-offset-parsing: the rejected hexadecimal offset still released artifact bytes on stdout" >&2
  exit 1
fi

# SN2: an offset beyond the /24 host range is rejected rather than wrapped or
# truncated onto an in-subnet address.
overflow_inventory="${tmp_dir}/inventory-overflow.nix"
write_inventory "${overflow_inventory}" '300'

if compile_inventory "${overflow_inventory}" >"${tmp_dir}/overflow.out" 2>"${tmp_dir}/overflow.err"; then
  echo "FAIL ipv4-decimal-offset-parsing: an out-of-range IPv4 offset (300 in a /24) was accepted instead of rejected" >&2
  exit 1
fi

if ! grep -F "IPv4 offset 300 overflows 10.20.20.0/24 capacity 256" "${tmp_dir}/overflow.err" >/dev/null; then
  echo "FAIL ipv4-decimal-offset-parsing: the out-of-range rejection did not name the offset, the subnet, and the capacity" >&2
  cat "${tmp_dir}/overflow.err" >&2
  exit 1
fi

if [[ -s "${tmp_dir}/overflow.out" ]]; then
  echo "FAIL ipv4-decimal-offset-parsing: the rejected out-of-range offset still released artifact bytes on stdout" >&2
  exit 1
fi

echo "PASS ipv4-decimal-offset-parsing"
