#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

intent_path="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/intent.nix"
inventory_path="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/inventory.nix"

[[ -f "${intent_path}" ]] || { echo "missing intent: ${intent_path}" >&2; exit 1; }
[[ -f "${inventory_path}" ]] || { echo "missing inventory: ${inventory_path}" >&2; exit 1; }

REPO_ROOT="${repo_root}" \
INTENT_PATH="${intent_path}" \
INVENTORY_PATH="${inventory_path}" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --expr '
      let
        flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
        out = flake.lib.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
        };
        branchPolicy =
          out.control_plane_model.data.espbranch."site-b".runtimeTargets."espbranch-site-b-b-router-policy".effectiveRuntimeRealization.interfaces;
        sitecPolicy =
          out.control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-policy".effectiveRuntimeRealization.interfaces;
        hasRoute = routes: destination: gateway:
          builtins.any
            (route:
              (route.dst or null) == destination
              && (
                (route.via4 or null) == gateway
                || (route.via6 or null) == gateway
              ))
            routes;
        hostile =
          branchPolicy."p2p-b-router-downstream-selector-b-router-policy--access-b-router-access-hostile".routes;
        media =
          sitecPolicy."p2p-c-router-downstream-selector-c-router-policy--access-c-router-access-media".routes;
        printer =
          sitecPolicy."p2p-c-router-downstream-selector-c-router-policy--access-c-router-access-printer".routes;
      in
        hasRoute (hostile.ipv4 or [ ]) "10.20.10.0/24" "10.50.0.11"
        && hasRoute (hostile.ipv6 or [ ]) "fd42:dead:beef:0010:0000:0000:0000:0000/64" "fd42:dead:feed:1000:0:0:0:b"
        && hasRoute (media.ipv4 or [ ]) "10.90.10.0/24" "10.80.0.16"
        && hasRoute (media.ipv6 or [ ]) "fd42:dead:cafe:0010:0000:0000:0000:0000/64" "fd42:dead:cafe:1000:0:0:0:10"
        && hasRoute (printer.ipv4 or [ ]) "10.90.10.0/24" "10.80.0.16"
        && hasRoute (printer.ipv6 or [ ]) "fd42:dead:cafe:0010:0000:0000:0000:0000/64" "fd42:dead:cafe:1000:0:0:0:10"
    ' | grep -qx true

echo "PASS dns-service-policy-routes"
