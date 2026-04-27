#!/usr/bin/env bash
set -euo pipefail

#example_repo=$(nix eval --raw --impure --expr 'builtins.fetchGit { url = "git@github.com:esp0xdeadbeef/network-labs.git";}')
#example_repo=$(nix flake prefetch github:esp0xdeadbeef/network-labs --json | jq -r .path)
#example_repo=$(nix flake prefetch github:esp0xdeadbeef/network-labs --json | jq -r .storePath)
example_repo=~/github/network-labs
INPUT="$example_repo/examples/single-wan/intent.nix"
INPUT_INVENTORY="$example_repo/examples/single-wan/inventory-nixos.nix"
INPUT="$example_repo/examples/multi-enterprise/intent.nix"
INPUT_INVENTORY="$example_repo/examples/tri-site-dual-wan-overlay-integration-static/inventory-nixos.nix"
OUTPUT="/tmp/output-control-plane-model.json"




# TEMP OVERWRITES:
#INPUT_INVENTORY="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-core/inventory-nixos.nix"
#INPUT_INVENTORY="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/inventory-nixos.nix"
##INPUT="/home/deadbeef/github/nixos/library/100-fabric-routing/inputs/intent.nix"
#INPUT="/home/deadbeef/github/nixos/library/100-fabric-routing/inputs/intent.nix"





rm -f "$OUTPUT"

echo "[*] Running control-plane-model..."
nix run .#compile-and-build-control-plane-model -- "$INPUT" "$INPUT_INVENTORY" "$OUTPUT" >/dev/null

echo "[*] Validating JSON..."
jq empty "$OUTPUT" >/dev/null

echo "[*] Output (compact JSON)..."
jq -c . "$OUTPUT"
