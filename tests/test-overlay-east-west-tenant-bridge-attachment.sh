#!/usr/bin/env bash
# GAMP-ID: FS-720-HDS-030-SDS-010-SMS-041
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

labs_path="$(pinned_network_labs)"
example_dir="${labs_path}/examples/overlay-east-west"
output_json="${tmp_dir}/cpm.json"

(
  cd "${repo_root}"
  nix run --show-trace "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${example_dir}/intent.nix" \
    "${example_dir}/inventory-clab.nix" \
    "${output_json}" >/dev/null
)

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    siteA = data.control_plane_model.data."enterprise-a"."site-a";
    siteB = data.control_plane_model.data."enterprise-b"."site-b";
    bridgeFor = site: target:
      site.runtimeTargets.${target}.effectiveRuntimeRealization.interfaces."tenant-mgmt".attach.bridge or null;
  in
    if
      bridgeFor siteA "enterprise-a-site-a-s-router-access" == "br-site-a-downstream-access"
      && bridgeFor siteB "enterprise-b-site-b-s-router-access" == "br-site-b-downstream-access"
    then
      true
    else
      throw "overlay-east-west tenant interface bridge attachment missing from CPM output"
' >/dev/null

echo "PASS overlay-east-west tenant bridge attachment"
