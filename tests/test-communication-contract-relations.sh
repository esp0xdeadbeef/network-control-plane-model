#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

intent_path="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/intent.nix"
inventory_path="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/inventory.nix"

[[ -f "$intent_path" ]] || { echo "missing intent: $intent_path" >&2; exit 1; }
[[ -f "$inventory_path" ]] || { echo "missing inventory: $inventory_path" >&2; exit 1; }

expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  built = flake.lib.${system}.compileAndBuildFromPaths {
    inputPath = builtins.getEnv "TEST_INPUT_PATH";
    inventoryPath = builtins.getEnv "TEST_INVENTORY_PATH";
  };
  site = built.control_plane_model.data.esp0xdeadbeef."site-c";
in
  builtins.any
    (relation: (relation.id or null) == "allow-sitec-home-to-local-services")
    ((site.communicationContract.relations or [ ]) ++ (site.communicationContract.allowedRelations or [ ]))
'

if TEST_INPUT_PATH="$intent_path" TEST_INVENTORY_PATH="$inventory_path" \
  nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS communication-contract-relations"
else
  echo "FAIL communication-contract-relations" >&2
  exit 1
fi
