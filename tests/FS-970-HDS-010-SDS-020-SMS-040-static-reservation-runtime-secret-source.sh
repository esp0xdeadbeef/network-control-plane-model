#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-020-SMS-040
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
write_inventory "${valid_inventory}" '[
  {
    id = "printer-reservation-10";
    macSource = {
      accepted = true;
      disposable = false;
      purpose = "static-dhcp-reservation";
      sourceClass = "protected";
      sourceFile = "/run/secrets/s-router-prod-vlan2-reservations.json";
    };
    ipv4.hostOffset = 10;
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
    reservation = builtins.elemAt dhcp4.reservations 0;
  in
    reservation.id == "printer-reservation-10"
    && reservation.address == "10.20.20.10"
    && !(reservation ? mac)
    && !(reservation ? hostname)
    && reservation.identitySource.sourceClass == "protected"
    && reservation.identitySource.sourceFile == "/run/secrets/s-router-prod-vlan2-reservations.json"
' | grep -qx true; then
  echo "FAIL static-reservation-runtime-secret-source: CPM did not emit a redacted runtime-secret reservation record" >&2
  exit 1
fi

secret_ref_only_inventory="${tmp_dir}/inventory-secret-ref-only.nix"
write_inventory "${secret_ref_only_inventory}" '[
  {
    id = "secret-ref-only";
    macSource = {
      accepted = true;
      disposable = false;
      purpose = "static-dhcp-reservation";
      sourceClass = "protected";
      secretRef = "sops://inventory/reservations/secret-ref-only";
    };
    ipv4.hostOffset = 11;
  }
]'

if compile_inventory "${secret_ref_only_inventory}" >"${tmp_dir}/secret-ref-only.out" 2>"${tmp_dir}/secret-ref-only.err"; then
  echo "FAIL static-reservation-runtime-secret-source: secretRef-only reservation without public MAC was accepted" >&2
  exit 1
fi
grep -F "diagnostic.runtime-reservation-source-file-missing" \
  "${tmp_dir}/secret-ref-only.err" >/dev/null || {
    echo "FAIL static-reservation-runtime-secret-source: NC2 secretRef-only did not emit diagnostic.runtime-reservation-source-file-missing" >&2
    cat "${tmp_dir}/secret-ref-only.err" >&2
    exit 1
  }
grep -F "requires complete MAC address or protected runtime sourceFile" \
  "${tmp_dir}/secret-ref-only.err" >/dev/null || {
    echo "FAIL static-reservation-runtime-secret-source: secretRef-only diagnostic was not concise" >&2
    cat "${tmp_dir}/secret-ref-only.err" >&2
    exit 1
  }

# NC1 - missing runtime source file: protected reservation with no public MAC
# and no macSource.sourceFile (and no secretRef) shall be rejected with
# diagnostic.runtime-reservation-source-file-missing.
missing_source_file_inventory="${tmp_dir}/inventory-missing-source-file.nix"
write_inventory "${missing_source_file_inventory}" '[
  {
    id = "missing-source-file";
    macSource = {
      accepted = true;
      disposable = false;
      purpose = "static-dhcp-reservation";
      sourceClass = "protected";
      source = "protected-inventory";
    };
    ipv4.hostOffset = 13;
  }
]'

if compile_inventory "${missing_source_file_inventory}" >"${tmp_dir}/missing-source-file.out" 2>"${tmp_dir}/missing-source-file.err"; then
  echo "FAIL static-reservation-runtime-secret-source: reservation with no public MAC and no sourceFile was accepted" >&2
  exit 1
fi
grep -F "diagnostic.runtime-reservation-source-file-missing" \
  "${tmp_dir}/missing-source-file.err" >/dev/null || {
    echo "FAIL static-reservation-runtime-secret-source: NC1 missing sourceFile did not emit diagnostic.runtime-reservation-source-file-missing" >&2
    cat "${tmp_dir}/missing-source-file.err" >&2
    exit 1
  }

unscoped_inventory="${tmp_dir}/inventory-unscoped-runtime-secret.nix"
write_inventory "${unscoped_inventory}" '[
  {
    macSource = {
      accepted = true;
      disposable = false;
      purpose = "static-dhcp-reservation";
      sourceClass = "protected";
      sourceFile = "/run/secrets/s-router-prod-vlan2-reservations.json";
    };
    ipv4.hostOffset = 12;
  }
]'

if compile_inventory "${unscoped_inventory}" >"${tmp_dir}/unscoped.out" 2>"${tmp_dir}/unscoped.err"; then
  echo "FAIL static-reservation-runtime-secret-source: runtime secret reservation without handle was accepted" >&2
  exit 1
fi
grep -F "diagnostic.reservation-identity-diagnostic-unscoped" \
  "${tmp_dir}/unscoped.err" >/dev/null || {
    echo "FAIL static-reservation-runtime-secret-source: unscoped diagnostic was not emitted" >&2
    cat "${tmp_dir}/unscoped.err" >&2
    exit 1
  }

echo "PASS static-reservation-runtime-secret-source"
