# ./test-control-plane-model.sh
#!/usr/bin/env bash
set -euo pipefail

#example_repo=$(nix eval --raw --impure --expr 'builtins.fetchGit { url = "git@github.com:esp0xdeadbeef/network-labs.git";}')
#example_repo=$(nix flake prefetch github:esp0xdeadbeef/network-labs --json | jq -r .path)
example_repo=$(nix flake prefetch github:esp0xdeadbeef/network-labs --json | jq -r .storePath)
#example_repo=~/github/network-labs
INPUT="$example_repo/examples/single-wan/intent.nix"
INPUT_INVENTORY="$example_repo/examples/single-wan/inventory.nix"
OUTPUT="output-control-plane-model.json"

rm -f "$OUTPUT"

echo "[*] Running control-plane-model..."
nix run .#control-plane-model -- "$INPUT" "$INPUT_INVENTORY" "$OUTPUT"

echo "[*] Validating JSON..."
jq empty "$OUTPUT" >/dev/null

echo "[*] Output (compact JSON)..."
jq -c . "$OUTPUT"
