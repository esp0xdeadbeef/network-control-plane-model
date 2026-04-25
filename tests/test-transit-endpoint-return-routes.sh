#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

search_root="$(nix flake archive --json "path:${repo_root}" | jq -er '.inputs["network-labs"].path')/examples"
example_root="${search_root}/dual-wan-branch-overlay-bgp"
intent_path="${example_root}/intent.nix"
inventory_path="${example_root}/inventory-nixos.nix"

[[ -f "${intent_path}" ]] || { echo "missing intent fixture: ${intent_path}" >&2; exit 1; }
[[ -f "${inventory_path}" ]] || { echo "missing inventory fixture: ${inventory_path}" >&2; exit 1; }

output_json="$(mktemp)"
sitec_json="$(mktemp)"
trap 'rm -f "'"${output_json}"'" "'"${sitec_json}"'"' EXIT

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
    hasRoute "ipv4" "10.10.0.8/32" "10.10.0.9"
    && hasRoute "ipv6" "fd42:dead:beef:1000:0:0:0:8/128" "fd42:dead:beef:1000:0:0:0:9"
' >/dev/null

REPO_ROOT="${repo_root}" \
INTENT_PATH="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/intent.nix" \
INVENTORY_PATH="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/inventory.nix" \
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
      in {
        policyIot = rt.effectiveRuntimeRealization.interfaces."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-iot--uplink-wan".routes;
        policyMgmt = rt.effectiveRuntimeRealization.interfaces."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-mgmt--uplink-wan".routes;
      }
    ' > "${sitec_json}"

OUTPUT_JSON="${sitec_json}" nix eval --impure --expr '
  let
    decoded = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    hasRoute = routes: destination:
      builtins.any
        (route:
          (route.dst or null) == destination
          && ((route.intent or { }).source or null) == "transit-endpoint")
        (routes.ipv4 or [ ]);
  in
    (!hasRoute decoded.policyIot "10.80.0.4/32")
    && hasRoute decoded.policyMgmt "10.80.0.4/32"
' >/dev/null

echo "PASS transit-endpoint-return-routes"
