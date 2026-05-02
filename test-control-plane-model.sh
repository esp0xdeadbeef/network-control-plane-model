#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

"$ROOT/tests/test-nix-file-loc.sh"

if command -v jq >/dev/null 2>&1; then
  jq_cmd=(jq)
else
  jq_cmd=(nix run nixpkgs#jq --)
fi

example_repo="$(
  nix flake archive --json "path:${ROOT}" \
    | "${jq_cmd[@]}" -er '.inputs["network-labs"].path'
)"

SCENARIO="tri-site-dual-wan-overlay-integration-bgp"
INPUT="$example_repo/examples/${SCENARIO}/intent.nix"
INPUT_INVENTORY="$example_repo/examples/${SCENARIO}/inventory-nixos.nix"
OUTPUT="/tmp/output-control-plane-model.json"
if [[ ! -f "$INPUT" || ! -f "$INPUT_INVENTORY" ]]; then
  echo "[!] Missing inputs for scenario '${SCENARIO}'"
  echo "    INPUT='$INPUT'"
  echo "    INPUT_INVENTORY='$INPUT_INVENTORY'"
  exit 1
fi

echo "[*] Using scenario: $SCENARIO"
echo "[*] INPUT: $INPUT"
echo "[*] INVENTORY: $INPUT_INVENTORY"

rm -f "$OUTPUT"

echo "[*] Running control-plane-model..."
nix run "path:${ROOT}#compile-and-build-control-plane-model" -- "$INPUT" "$INPUT_INVENTORY" "$OUTPUT" >/dev/null

echo "[*] Validating JSON..."
jq empty "$OUTPUT" >/dev/null

echo "[*] Output (compact JSON)..."
jq -c . "$OUTPUT"
