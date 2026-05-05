#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

search_root="$(nix flake archive --json "path:${repo_root}" | jq -er '.inputs["network-labs"].path')/examples"
example_root="${search_root}/dual-wan-branch-overlay-bgp"
intent_path="${example_root}/intent.nix"
inventory_path="${example_root}/inventory-nixos.nix"
s_router_example_root="${search_root}/s-router-overlay-dns-lane-policy"
s_router_intent_path="${s_router_example_root}/intent.nix"
s_router_inventory_path="${s_router_example_root}/inventory-nixos.nix"

[[ -f "${intent_path}" ]] || { echo "missing intent fixture: ${intent_path}" >&2; exit 1; }
[[ -f "${inventory_path}" ]] || { echo "missing inventory fixture: ${inventory_path}" >&2; exit 1; }

output_json="$(mktemp)"
sitec_json="$(mktemp)"
trap 'rm -f "'"${output_json}"'" "'"${output_json}.check"'" "'"${sitec_json}"'" "'"${sitec_json}.checks"'"' EXIT

REPO_ROOT="${repo_root}" \
INTENT_PATH="${intent_path}" \
INVENTORY_PATH="${inventory_path}" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
        out = flake.libBySystem.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
        };
      in
        out.control_plane_model.data.enterpriseA."site-a".runtimeTargets."enterpriseA-site-a-s-router-core-isp-a"
          .effectiveRuntimeRealization.interfaces."p2p-s-router-core-isp-a-s-router-upstream-selector".routes
    ' > "${output_json}"

# shellcheck disable=SC2016
OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    routes = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    hasRoute = family: dst: via:
      builtins.any
        (route:
          (route.dst or null) == dst
          && (
            if family == "ipv4" then
              (route.via4 or null) == via
            else
              (route.via6 or null) == via
          )
          && ((route.intent or { }).kind or null) == "internal-reachability"
        )
        (routes.${family} or [ ]);
  in
    hasRoute "ipv4" "10.19.0.8/32" "10.10.0.9"
    && (
      hasRoute "ipv6" "fd42:dead:beef:1900:0000:0000:0000:0008/128" "fd42:dead:beef:1000:0:0:0:9"
      || hasRoute "ipv6" "fd42:dead:beef:1900:0:0:0:8/128" "fd42:dead:beef:1000:0:0:0:9"
    )
' > "${output_json}.check"

if ! grep -qx true "${output_json}.check"; then
  echo "FAIL transit-endpoint-return-routes: isp-a return routes missing" >&2
  echo "resolved routes:" >&2
  jq . "${output_json}" >&2
  exit 1
fi

REPO_ROOT="${repo_root}" \
INTENT_PATH="${s_router_intent_path}" \
INVENTORY_PATH="${s_router_inventory_path}" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
        out = flake.libBySystem.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
        };
        rt = out.control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector";
        branchCore = out.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets."esp0xdeadbeef-site-a-s-router-core-nebula";
        branchNebulaCore = out.control_plane_model.data.espbranch."site-b".runtimeTargets."espbranch-site-b-b-router-core-nebula";
      in {
        policyClientEastWest = rt.effectiveRuntimeRealization.interfaces."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-client--uplink-east-west".routes;
        policyClientWan = rt.effectiveRuntimeRealization.interfaces."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-client--uplink-wan".routes;
        policyDmzEastWest = rt.effectiveRuntimeRealization.interfaces."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-east-west".routes;
        policyDmzWan = rt.effectiveRuntimeRealization.interfaces."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-wan".routes;
        branchOverlay = branchCore.effectiveRuntimeRealization.interfaces."overlay-east-west".routes;
        branchNebulaUpstream = branchNebulaCore.effectiveRuntimeRealization.interfaces."p2p-b-router-core-nebula-b-router-upstream-selector".routes;
      }
    ' > "${sitec_json}"

jq '
  def has_transit_route4($routes; $destination):
    any(($routes.ipv4 // [])[]; .dst == $destination and ((.intent // {}).source == "transit-endpoint"));
  def has_transit_route6($routes; $destination):
    any(($routes.ipv6 // [])[]; .dst == $destination and ((.intent // {}).source == "transit-endpoint"));
  def has_internal_route4($routes; $destination):
    any(($routes.ipv4 // [])[]; .dst == $destination and ((.intent // {}).kind == "internal-reachability"));
  def has_default4($routes; $via):
    any(($routes.ipv4 // [])[]; .dst == "0.0.0.0/0" and .via4 == $via);
  def has_default6($routes; $via):
    any(($routes.ipv6 // [])[]; (.dst == "::/0" or .dst == "0000:0000:0000:0000:0000:0000:0000:0000/0") and .via6 == $via);
  {
    clientEastWestDoesNotLearnWanCoreHost: (has_transit_route4(.policyClientEastWest; "10.80.0.4/32") | not),
    dmzEastWestDoesNotLearnWanCoreHost: (has_transit_route4(.policyDmzEastWest; "10.80.0.4/32") | not),
    dmzWanDoesNotLearnWanCoreHost: (has_transit_route4(.policyDmzWan; "10.80.0.4/32") | not),
    clientEastWestKeepsAccessP2pAggregate: has_internal_route4(.policyClientEastWest; "10.80.0.0/30"),
    branchOverlayHasAccessReturnV4: has_transit_route4(.branchOverlay; "10.50.0.0/32"),
    branchOverlayHasAccessReturnV6: has_transit_route6(.branchOverlay; "fd42:dead:feed:1000:0:0:0:0/128"),
    branchNebulaCoreKeepsUnderlayDefaultV4: has_default4(.branchNebulaUpstream; "10.50.0.5"),
    branchNebulaCoreKeepsUnderlayDefaultV6: has_default6(.branchNebulaUpstream; "fd42:dead:feed:1000:0:0:0:5")
  }
' "${sitec_json}" > "${sitec_json}.checks"

failed_checks="$(jq -r 'to_entries[] | select(.value != true) | .key' "${sitec_json}.checks")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL transit-endpoint-return-routes" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  echo "resolved checks:" >&2
  jq . "${sitec_json}.checks" >&2
  echo "resolved routes:" >&2
  jq . "${sitec_json}" >&2
  exit 1
fi

echo "PASS transit-endpoint-return-routes"
