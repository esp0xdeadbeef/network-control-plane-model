#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-DNS-ACCESS-SELF-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-006
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-013-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-006
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-013-SMS-001-CMC-001-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

archive_json="$(mktemp)"
output_json="$(mktemp)"
trap 'rm -f "${archive_json}" "${output_json}"' EXIT

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then
        throw "tests: missing archived network-labs input path"
      else
        labsPath
  '
)"

REPO_ROOT="${repo_root}" \
INTENT_PATH="${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
INVENTORY_PATH="${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
        out = flake.lib.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
        };
        dns =
          out.control_plane_model.data.esp0xdeadbeef."site-c"
            .runtimeTargets."esp0xdeadbeef-site-c-c-router-access-dmz".services.dns;
        hasAll = expected: actual:
          builtins.all (value: builtins.elem value actual) expected;
      in {
        ok =
          hasAll [ "10.90.10.1" "fd42:dead:cafe:10::1" ] (dns.listen or [ ])
          && hasAll [ "10.90.10.0/24" "fd42:dead:cafe:10::/64" ] (dns.allowFrom or [ ])
          && hasAll [ "10.90.10.1" "fd42:dead:cafe:10::1" ] (dns.outgoingInterfaces or [ ])
          && hasAll [ "1.1.1.1" "9.9.9.9" ] (dns.forwarders or [ ])
          && hasAll [ "2606:4700:4700::1111" "2620:fe::fe" ] (dns.forwarders or [ ])
          && (dns.blockDirectEgress or false);
        inherit dns;
      }
    ' > "${output_json}"

if ! jq -e '.ok == true' "${output_json}" >/dev/null; then
  echo "FAIL access-dns-router-self-listeners" >&2
  jq '.dns' "${output_json}" >&2
  exit 1
fi

echo "PASS access-dns-router-self-listeners"
