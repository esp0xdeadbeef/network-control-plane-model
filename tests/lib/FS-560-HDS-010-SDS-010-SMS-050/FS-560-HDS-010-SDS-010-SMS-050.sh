#!/usr/bin/env bash
# GAMP-ID: FS-560-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

command -v jq >/dev/null 2>&1 || {
  echo "missing required command: jq" >&2
  exit 1
}

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
  local name_publication="$2"
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
              reservationSource = {
                schema = "gamp-protected-reservation-set-v1";
                sourceClass = "protected";
                sourceFile = "/run/secrets/test-reservations.json";
                ${name_publication}
              };
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

valid_inventory="${tmp_dir}/inventory-valid.nix"
write_inventory "${valid_inventory}" '
  namePublication = {
    namespace = "client.lan.";
    ownerScope = "client";
    requesterScopes = [ "client" ];
    recordClasses = [ "A" "AAAA" "PTR" ];
    fallbackBehavior = "local-only";
    publicationDenialDiagnostic = "diagnostic.protected-reservation-name-publication-denied";
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
    publication = builtins.head target.services.dns.protectedReservationPublications;
  in
    dhcp4.reservations == [ ]
    && dhcp4.reservationSource.sourceFile == "/run/secrets/test-reservations.json"
    && publication == {
      source = {
        schema = "gamp-protected-reservation-set-v1";
        sourceClass = "protected";
        sourceFile = "/run/secrets/test-reservations.json";
      };
      scopeId = "client";
      namespace = "client.lan.";
      ownerScope = "client";
      requesterScopes = [ "client" ];
      recordClasses = [ "A" "AAAA" "PTR" ];
      materializerFamily = "ipv4";
      fallbackBehavior = "local-only";
      publicationDenialDiagnostic = "diagnostic.protected-reservation-name-publication-denied";
    }
    && !(publication ? records)
    && !(publication ? hostname)
    && !(publication ? mac)
    && !(publication ? ipv4)
    && !(publication ? ipv6)
' | grep -qx true; then
  echo "FAIL protected-reservation-name-materialization: CPM did not emit one opaque, scope-bound DNS publication contract" >&2
  exit 1
fi

assert_rejected() {
  local case_name="$1"
  local diagnostic="$2"
  local publication="$3"
  local inventory="${tmp_dir}/inventory-${case_name}.nix"
  local stderr_file="${tmp_dir}/${case_name}.err"

  write_inventory "${inventory}" "${publication}"
  if compile_inventory "${inventory}" >"${tmp_dir}/${case_name}.out" 2>"${stderr_file}"; then
    echo "FAIL protected-reservation-name-materialization: ${case_name} was accepted" >&2
    exit 1
  fi
  if ! grep -F "${diagnostic}" "${stderr_file}" >/dev/null; then
    echo "FAIL protected-reservation-name-materialization: ${case_name} did not emit ${diagnostic}" >&2
    cat "${stderr_file}" >&2
    exit 1
  fi
}

assert_rejected owner-mismatch diagnostic.protected-reservation-name-owner-mismatch '
  namePublication = {
    namespace = "client.lan.";
    ownerScope = "other";
    requesterScopes = [ "other" ];
    recordClasses = [ "A" ];
    fallbackBehavior = "local-only";
    publicationDenialDiagnostic = "diagnostic.denied";
  };
'

assert_rejected wildcard-scope diagnostic.protected-reservation-name-scope-wildcard '
  namePublication = {
    namespace = "client.lan.";
    ownerScope = "client";
    requesterScopes = [ "client" "*" ];
    recordClasses = [ "A" ];
    fallbackBehavior = "local-only";
    publicationDenialDiagnostic = "diagnostic.denied";
  };
'

assert_rejected inline-records diagnostic.protected-reservation-name-publication-field-invalid '
  namePublication = {
    namespace = "client.lan.";
    ownerScope = "client";
    requesterScopes = [ "client" ];
    recordClasses = [ "A" ];
    fallbackBehavior = "local-only";
    publicationDenialDiagnostic = "diagnostic.denied";
    records = [ { hostname = "must-not-enter-cpm"; } ];
  };
'

echo "PASS protected-reservation-name-materialization"
