#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_json="$(mktemp)"
output_json="$(mktemp)"
violations_json="$(mktemp)"
trap 'rm -f "${archive_json}" "${output_json}" "${violations_json}"' EXIT

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

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -r '
  .control_plane_model.data
  | to_entries[] as $enterprise
  | $enterprise.value
  | to_entries[] as $site
  | $site.value.runtimeTargets
  | to_entries[]
  | select((.value.role // "") == "upstream-selector")
  | . as $target
  | ($target.value.forwardingIntent.rules // [])
  | to_entries[]
  | select(
      (.value.action // "") == "accept"
      and (.value.fromInterface // "" | startswith("core-"))
      and (.value.toInterface // "" | startswith("core-"))
    )
  | "!!!! " + $enterprise.key + "." + $site.key
    + " upstream-selector=" + $target.key
    + " CPM illegally cross-connects cores: "
    + (.value.fromInterface // "<missing>")
    + " -> "
    + (.value.toInterface // "<missing>")
' "${output_json}" >"${violations_json}"

if [[ -s "${violations_json}" ]]; then
  cat "${violations_json}" >&2
  exit 1
fi

echo "PASS upstream-selector-no-core-crossconnect"
