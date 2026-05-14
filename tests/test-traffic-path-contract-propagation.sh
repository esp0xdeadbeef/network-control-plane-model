#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "traffic-path-contract-propagation: missing network-labs input" else labsPath
  '
)"

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -e '
  [
    .control_plane_model.data[][]?.trafficPaths[]?
    | select(.requiresPolicy == true)
    | select(.forbidsCoreToCoreP2P == true)
    | select((.stagePath | index("policy")) != null)
    | select((.nodePathAlternatives | length) >= 1)
    | select(.p2pIsolationKey == .relationId)
  ] | length > 0
' "${output_json}" >/dev/null

echo "PASS traffic-path-contract-propagation"
