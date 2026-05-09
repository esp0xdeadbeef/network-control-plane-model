#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_json="$(mktemp)"
out_dir="$(mktemp -d)"
violations_jsonl="$(mktemp)"
trap 'rm -f "${archive_json}" "${violations_jsonl}"; rm -rf "${out_dir}"' EXIT

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

: >"${violations_jsonl}"

for example in \
  single-wan-with-nebula \
  single-wan-with-nebula-any-to-any-fw \
  overlay-east-west \
  dual-wan-branch-overlay \
  dual-wan-branch-overlay-bgp \
  s-router-overlay-dns-lane-policy
do
  example_dir="${labs_path}/examples/${example}"
  output_json="${out_dir}/${example}.json"

  nix run "${repo_root}#compile-and-build-control-plane-model" -- \
    "${example_dir}/intent.nix" \
    "${example_dir}/inventory-nixos.nix" \
    "${output_json}" >/dev/null

  jq -r --arg example "${example}" '
    .control_plane_model.data
    | to_entries[] as $enterprise
    | $enterprise.value
    | to_entries[] as $site
    | ($site.value.overlays // {})
    | to_entries[]
    | select((.value.provider // "") == "nebula")
    | select((.value.nebula // null) == null)
    | "!!!! "
      + $example
      + " "
      + $enterprise.key
      + "."
      + $site.key
      + " overlay="
      + .key
      + " declares provider=nebula but has no provider-specific nebula contract"
  ' "${output_json}" >>"${violations_jsonl}"
done

if [[ -s "${violations_jsonl}" ]]; then
  cat "${violations_jsonl}" >&2
  exit 1
fi

echo "PASS nebula-overlays-have-provider-contract"
