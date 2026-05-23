#!/usr/bin/env bash
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
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "delegated-public-egress-peer-site: missing network-labs input" else labsPath
  '
)"

example_dir="${labs_path}/examples/s-router-overlay-dns-lane-policy"
nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${example_dir}/intent.nix" \
  "${example_dir}/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -e '
  def delegated_defaults($site; $target):
    [$site.runtimeTargets[$target].effectiveRuntimeRealization.interfaces."overlay-east-west".routes.ipv6[]?
      | select(
          .dst == "::/0"
          and (.intent.kind // "") == "delegated-public-egress"
          and (.intent.exitNode // "") == "b-router-access-hostile"
          and (.policyOnly // false) == true
        )];
  .control_plane_model.data as $data
  | delegated_defaults($data.espbranch["site-b"]; "espbranch-site-b-b-router-core-nebula") as $branchDefaults
  | ($branchDefaults | length) == 1
' "${output_json}" >/dev/null || {
  echo "FAIL delegated-public-egress-peer-site: delegated public-egress defaults must preserve the selected example exit node" >&2
  exit 1
}

echo "PASS delegated-public-egress-peer-site"
