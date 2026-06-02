#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-OVERLAY-PEER-SITE-PRESERVATION-001
# GAMP-SCOPE: software-module-test
set -euo pipefail
# LAB-SMT-ID: LAB-SMT-006
# LAB-SMT-SCOPE: examples-only; see network-labs/tests/SMT.md

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"
violations_json="${tmp_dir}/violations.json"

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "overlay-peer-site-preservation: missing network-labs input" else labsPath
  '
)"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq '
  [
    paths as $p
    | getpath($p) as $route
    | select(
        ($route | type) == "object"
        and (($route.intent.kind? // "") == "overlay-reachability")
        and ((($route.overlay? // "") == "") or (($route.peerSite? // "") == ""))
      )
    | {
        path: ($p | map(tostring) | join(".")),
        route: $route
      }
  ]
' "${output_json}" > "${violations_json}"

if jq -e 'length == 0' "${violations_json}" >/dev/null; then
  echo "PASS overlay-peer-site-preservation"
else
  echo "FAIL overlay-peer-site-preservation: CPM emitted overlay-reachability without overlay or peerSite" >&2
  jq '.[0:20]' "${violations_json}" >&2
  exit 1
fi
