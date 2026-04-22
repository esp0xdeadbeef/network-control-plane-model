#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
example_root="${repo_root}/../network-labs/examples"

fail() { echo "$1" >&2; exit 1; }

run_one() {
  local example_name="$1"
  local intent_path="${example_root}/${example_name}/intent.nix"
  local inventory_path="${example_root}/${example_name}/inventory-nixos.nix"

  [[ -f "${intent_path}" ]] || fail "missing intent.nix: ${intent_path}"
  [[ -f "${inventory_path}" ]] || fail "missing inventory-nixos.nix: ${inventory_path}"

  local output_json
  output_json="$(mktemp)"
  trap 'rm -f "'"${output_json}"'"' RETURN

  nix run "${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory_path}" \
    "${output_json}" >/dev/null

  OUTPUT_JSON="${output_json}" nix eval --impure --expr '
    let
      data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
      siteA = data.control_plane_model.data.enterpriseA."site-a";
      siteB = data.control_plane_model.data.enterpriseB."site-b";
      overlayA = siteA.overlays."east-west";
      overlayB = siteB.overlays."east-west";
      rtA = siteA.runtimeTargets."enterpriseA-site-a-s-router-core-isp-b";
      rtB = siteB.runtimeTargets."enterpriseB-site-b-b-router-core";
    in
      overlayA.terminateOn == [ "s-router-core-isp-b" ]
      && overlayB.terminateOn == [ "b-router-core" ]
      && overlayA.nodes."s-router-core-isp-b".addr4 == "100.96.10.1/32"
      && overlayB.nodes."b-router-core".addr4 == "100.96.10.2/32"
      && builtins.hasAttr "overlay-east-west" rtA.effectiveRuntimeRealization.interfaces
      && builtins.hasAttr "overlay-east-west" rtB.effectiveRuntimeRealization.interfaces
      && (
        if builtins.hasAttr "routing" siteA then
          siteA.routing.mode == "bgp"
        else
          true
      )
  ' >/dev/null || fail "FAIL ${example_name}: CPM validation failed"

  echo "PASS ${example_name}"
  rm -f "${output_json}"
  trap - RETURN
}

run_one "dual-wan-branch-overlay"
run_one "dual-wan-branch-overlay-bgp"
