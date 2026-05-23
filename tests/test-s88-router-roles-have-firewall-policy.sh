#!/usr/bin/env bash
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

# !!!! This is intentionally a CPM boundary alarm, not a renderer nft test.
# If a forwarding router role reaches CPM with zero firewall rules, either CPM
# failed to project upstream communication policy into role-local rules, or an
# upstream model failed to provide the policy surface CPM needs. Core nodes with
# no realized uplink forwarding interface are allowed to be explicit no-forward
# endpoints; renderers must keep those fail-closed instead of inventing transit
# policy from names or interfaces.
: >"${violations_jsonl}"

for inventory in "${labs_path}"/examples/*/inventory-nixos.nix; do
  example_dir="$(dirname "${inventory}")"
  example="$(basename "${example_dir}")"
  output_json="${out_dir}/${example}.json"

  nix run "${repo_root}#compile-and-build-control-plane-model" -- \
    "${example_dir}/intent.nix" \
    "${inventory}" \
    "${output_json}" >/dev/null

  jq -r --arg example "${example}" '
    .control_plane_model.data
    | to_entries[] as $enterprise
    | $enterprise.value
    | to_entries[] as $site
    | $site.value.runtimeTargets
    | to_entries[]
    | select((.value.role // "") as $role
        | ["access", "upstream-selector", "policy", "downstream-selector", "core"]
        | index($role))
    | select(((.value.forwardingIntent.rules // []) | length) == 0)
    | select(
        (.value.role // "") != "core"
        or (((.value.forwardingIntent.uplinkInterfaces // []) | length) > 0)
      )
    | "!!!! "
      + $example
      + " "
      + $enterprise.key
      + "."
      + $site.key
      + " runtimeTarget="
      + .key
      + " role="
      + (.value.role // "<missing>")
      + " mode="
      + (.value.forwardingIntent.mode // "<missing>")
      + " emitted an empty S88 firewall policy"
  ' "${output_json}" >>"${violations_jsonl}"
done

if [[ -s "${violations_jsonl}" ]]; then
  cat "${violations_jsonl}" >&2
  exit 1
fi

echo "PASS s88-router-roles-have-firewall-policy"
