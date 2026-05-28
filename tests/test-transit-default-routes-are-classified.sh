#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-TRANSIT-DEFAULT-CLASS-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
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
  single-wan-any-to-any-fw \
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
    | $site.value.runtimeTargets
    | to_entries[] as $target
    | select(($target.value.role // "") as $role
        | ["policy", "upstream-selector", "downstream-selector"]
        | index($role))
    | ($target.value.effectiveRuntimeRealization.interfaces // {})
    | to_entries[] as $iface
    | ($iface.value.routes.ipv4 // []), ($iface.value.routes.ipv6 // [])
    | .[]?
    | select((.dst // "") == "0.0.0.0/0" or (.dst // "") == "::/0")
    | select((.policyOnly // false) != true)
    | "!!!! "
      + $example
      + " "
      + $enterprise.key
      + "."
      + $site.key
      + " runtimeTarget="
      + $target.key
      + " role="
      + ($target.value.role // "<missing>")
      + " interface="
      + $iface.key
      + " default="
      + (.dst // "<missing>")
      + " is not explicitly policyOnly"
  ' "${output_json}" >>"${violations_jsonl}"
done

if [[ -s "${violations_jsonl}" ]]; then
  cat "${violations_jsonl}" >&2
  exit 1
fi

echo "PASS transit-default-routes-are-classified"
