#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-020-SMS-040
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
  local dhcp4_reservation_contract="$2"
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
              ${dhcp4_reservation_contract}
            };
          };
          dhcpv6 = { };
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

valid_inventory="${tmp_dir}/inventory-valid-runtime-secret.nix"
write_inventory "${valid_inventory}" '
  reservationSource = {
    schema = "gamp-protected-reservation-set-v1";
    sourceClass = "protected";
    sourceFile = "/run/secrets/s-router-prod-vlan2-reservations.json";
  };
'

output_json="${tmp_dir}/out.json"
compile_inventory "${valid_inventory}" >"${output_json}"

if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    target = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    dhcp4 = builtins.head target.advertisements.dhcp4;
    source = dhcp4.reservationSource;
  in
    dhcp4.reservations == [ ]
    && source.schema == "gamp-protected-reservation-set-v1"
    && source.sourceClass == "protected"
    && source.sourceFile == "/run/secrets/s-router-prod-vlan2-reservations.json"
    && source.binderSourceAudit.stage == "control-plane-model"
    && source.binderSourceAudit.sourceClass == "protected-inventory"
    && !(source ? records)
    && !(source ? id)
    && !(source ? address)
    && !(source ? mac)
    && !(source ? hostname)
' | grep -qx true; then
  echo "FAIL static-reservation-runtime-secret-source: CPM did not emit one redacted advertisement-level protected reservation source" >&2
  exit 1
fi

missing_source_file_inventory="${tmp_dir}/inventory-missing-source-file.nix"
write_inventory "${missing_source_file_inventory}" '
  reservationSource = {
    schema = "gamp-protected-reservation-set-v1";
    sourceClass = "protected";
  };
'

if compile_inventory "${missing_source_file_inventory}" >"${tmp_dir}/missing-source-file.out" 2>"${tmp_dir}/missing-source-file.err"; then
  echo "FAIL static-reservation-runtime-secret-source: advertisement-level protected source without sourceFile was accepted" >&2
  exit 1
fi
grep -F "diagnostic.runtime-reservation-source-file-missing" \
  "${tmp_dir}/missing-source-file.err" >/dev/null || {
    echo "FAIL static-reservation-runtime-secret-source: missing sourceFile did not emit diagnostic.runtime-reservation-source-file-missing" >&2
    cat "${tmp_dir}/missing-source-file.err" >&2
    exit 1
  }

public_source_inventory="${tmp_dir}/inventory-public-source.nix"
write_inventory "${public_source_inventory}" '
  reservationSource = {
    schema = "gamp-protected-reservation-set-v1";
    sourceClass = "public-inventory";
    sourceFile = "/run/secrets/s-router-prod-vlan2-reservations.json";
  };
'

if compile_inventory "${public_source_inventory}" >"${tmp_dir}/public-source.out" 2>"${tmp_dir}/public-source.err"; then
  echo "FAIL static-reservation-runtime-secret-source: non-protected reservation set source was accepted" >&2
  exit 1
fi
grep -F "diagnostic.protected-reservation-identity-leaked" \
  "${tmp_dir}/public-source.err" >/dev/null || {
    echo "FAIL static-reservation-runtime-secret-source: non-protected source did not emit the protected boundary diagnostic" >&2
    cat "${tmp_dir}/public-source.err" >&2
    exit 1
  }

inline_records_inventory="${tmp_dir}/inventory-inline-records.nix"
write_inventory "${inline_records_inventory}" '
  reservationSource = {
    schema = "gamp-protected-reservation-set-v1";
    sourceClass = "protected";
    sourceFile = "/run/secrets/s-router-prod-vlan2-reservations.json";
    records = [ { id = "must-not-be-public"; } ];
  };
'

if compile_inventory "${inline_records_inventory}" >"${tmp_dir}/inline-records.out" 2>"${tmp_dir}/inline-records.err"; then
  echo "FAIL static-reservation-runtime-secret-source: public per-client records inside reservationSource were accepted" >&2
  exit 1
fi
grep -F "diagnostic.protected-reservation-identity-leaked" \
  "${tmp_dir}/inline-records.err" >/dev/null || {
    echo "FAIL static-reservation-runtime-secret-source: inline protected record did not emit the protected boundary diagnostic" >&2
    cat "${tmp_dir}/inline-records.err" >&2
    exit 1
  }

conflicting_inventory="${tmp_dir}/inventory-conflicting-source-and-record.nix"
write_inventory "${conflicting_inventory}" '
  reservationSource = {
    schema = "gamp-protected-reservation-set-v1";
    sourceClass = "protected";
    sourceFile = "/run/secrets/s-router-prod-vlan2-reservations.json";
  };
  reservations = [
    {
      id = "public-reservation";
      mac = "02:00:00:00:00:10";
      macSource = {
        accepted = true;
        disposable = true;
        purpose = "static-dhcp-reservation";
        sourceClass = "public-synthetic-lab";
      };
      ipv4.hostOffset = 10;
    }
  ];
'

if compile_inventory "${conflicting_inventory}" >"${tmp_dir}/conflicting.out" 2>"${tmp_dir}/conflicting.err"; then
  echo "FAIL static-reservation-runtime-secret-source: reservationSource plus public per-client descriptors was accepted" >&2
  exit 1
fi
grep -F "diagnostic.runtime-reservation-source-conflict" \
  "${tmp_dir}/conflicting.err" >/dev/null || {
    echo "FAIL static-reservation-runtime-secret-source: source/descriptor conflict diagnostic was not emitted" >&2
    cat "${tmp_dir}/conflicting.err" >&2
    exit 1
  }

per_record_source_inventory="${tmp_dir}/inventory-per-record-source.nix"
write_inventory "${per_record_source_inventory}" '
  reservations = [
    {
      id = "private-descriptor";
      macSource = {
        accepted = true;
        disposable = false;
        purpose = "static-dhcp-reservation";
        sourceClass = "protected";
        sourceFile = "/run/secrets/s-router-prod-vlan2-reservations.json";
      };
      ipv4.hostOffset = 12;
    }
  ];
'

if compile_inventory "${per_record_source_inventory}" >"${tmp_dir}/per-record-source.out" 2>"${tmp_dir}/per-record-source.err"; then
  echo "FAIL static-reservation-runtime-secret-source: per-reservation protected source descriptor was accepted" >&2
  exit 1
fi
grep -F "diagnostic.runtime-reservation-source-must-be-scope-level" \
  "${tmp_dir}/per-record-source.err" >/dev/null || {
    echo "FAIL static-reservation-runtime-secret-source: per-record protected source did not emit the scope-level diagnostic" >&2
    cat "${tmp_dir}/per-record-source.err" >&2
    exit 1
  }

echo "PASS static-reservation-runtime-secret-source"
