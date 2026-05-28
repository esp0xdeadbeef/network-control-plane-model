#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-OVERLAY-IPV6-IPAM-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then throw "tests: missing archived network-labs input path" else labsPath
  '
)"

intent_path="${labs_path}/examples/single-wan-with-nebula/intent.nix"
inventory_path="${labs_path}/examples/single-wan-with-nebula/inventory-nixos.nix"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${inventory_path}" \
  "${output_json}" >/dev/null

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    node = data.control_plane_model.data.esp0xdeadbeef."site-a".overlays.nebula.nodes."s-router-core-nebula";
  in
    node.addr4 == "100.96.10.1/32"
    && node.addr6 == "fd42:dead:beef:ee::1/128"
' >/dev/null || {
  echo "!!!! overlay-ipv6-auto-allocation: CPM must preserve explicit inventory overlay node addresses while taking overlay pool policy from NFM; this is CPM inventory-to-overlay realization, not renderer guessing" >&2
  exit 1
}

echo "PASS overlay-ipv6-auto-allocation"
