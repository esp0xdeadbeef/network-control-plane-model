#!/usr/bin/env bash
set -euo pipefail

INPUT="../network-compiler/examples/single-wan/inputs.nix"
EXPECTED="./output-solver-signed.json"
OUTPUT="control-plane-model.json"

rm -f "$OUTPUT"

echo "[*] Running control-plane-model..."
nix run .#control-plane-model -- "$INPUT" "$OUTPUT"

echo "[*] Validating JSON..."
jq empty "$OUTPUT" >/dev/null

echo "[*] Verifying Phase 1 pass-through (exact match with solver output)..."

TMP_EXPECTED="$(mktemp)"
trap 'rm -f "$TMP_EXPECTED"' EXIT

# regenerate solver output exactly like pipeline does
echo "[*] Running solver separately for comparison..."
nix run github:esp0xdeadbeef/network-forwarding-model#compile-and-solve -- "$INPUT" > "$TMP_EXPECTED"

jq empty "$TMP_EXPECTED" >/dev/null

if diff -u <(jq -S . "$TMP_EXPECTED") <(jq -S . "$OUTPUT") ; then
  echo "[✓] PASS: control-plane-model output is identical to forwarding model"
else
  echo "[✗] FAIL: outputs differ"
  exit 1
fi

echo "[*] Preview output..."
jq '.enterprise | keys' "$OUTPUT"
