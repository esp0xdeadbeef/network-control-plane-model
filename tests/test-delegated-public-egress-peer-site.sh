#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "delegated-public-egress-peer-site: missing network-labs input" else labsPath
  '
)"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/labs/lab-s-sigma/s-router-test-three-site/intent.nix" \
    "${labs_path}/labs/lab-s-sigma/s-router-test-three-site/inventory.nix" \
    "${output_json}" >/dev/null
)

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    delegatedDefaultsFor = site: target:
      builtins.filter
        (route:
          (route.dst or null) == "::/0"
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && (route.policyOnly or false) == true)
        (((site.runtimeTargets.${target}.effectiveRuntimeRealization.interfaces."overlay-east-west" or { }).routes or { }).ipv6 or [ ]);
    nixosDefaults = delegatedDefaultsFor data.control_plane_model.data.esp.nixos "esp-nixos-router-core-nebula";
    clabDefaults = delegatedDefaultsFor data.control_plane_model.data.esp.clab "esp-clab-router-core-nebula";
    allDefaultsTargetHetz =
      routes:
      routes != [ ] && builtins.all (route: (route.peerSite or null) == "esp.hetz") routes;
  in
    if allDefaultsTargetHetz nixosDefaults && allDefaultsTargetHetz clabDefaults then
      true
    else
      throw "delegated-public-egress-peer-site failed: multi-peer delegated public-egress defaults must carry peerSite=esp.hetz so renderers do not fall back to another overlay peer"
' >/dev/null

echo "PASS delegated-public-egress-peer-site"
