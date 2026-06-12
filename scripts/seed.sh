#!/usr/bin/env bash
# scripts/seed.sh — Generate cached NFM output for CPM tests.
#
# Runs the compiler → NFM pipeline to produce a JSON fixture that CPM tests
# can consume as pre-built forwarding-model input, avoiding repeated
# compilation during test development.
#
# Usage:
#   ./scripts/seed.sh <intent.nix> <inventory.nix> [output.json]
#
#   intent.nix    — path to intent file (e.g., network-labs/intents/s-router.nix)
#   inventory.nix — path to inventory file (e.g., network-labs/inventories/s-router.nix)
#   output.json   — optional output path (default: tests/fixtures/nfm-output.json)
#
# Idempotent: skips regeneration if output.json is newer than both inputs.
#
# NOT run automatically in tests — this is a development tool for caching
# expensive pipeline output during test authoring.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ============================================================
# Usage
# ============================================================
usage() {
  echo "Usage: $(basename "$0") <intent.nix> <inventory.nix> [output.json]"
  echo ""
  echo "  intent.nix    — path to intent file"
  echo "  inventory.nix — path to inventory file"
  echo "  output.json   — optional output path (default: tests/fixtures/nfm-output.json)"
  echo ""
  echo "Generates cached NFM JSON output for CPM tests."
  echo "Skips regeneration if output is newer than both inputs (idempotent)."
  exit 1
}

if [[ "${#}" -lt 2 ]]; then
  usage
fi

intent_path="${1}"
inventory_path="${2}"
output_path="${3:-${repo_root}/tests/fixtures/nfm-output.json}"

# ============================================================
# Input validation
# ============================================================
if [[ ! -f "${intent_path}" ]]; then
  echo "ERROR: intent file not found: ${intent_path}" >&2
  exit 1
fi

if [[ ! -f "${inventory_path}" ]]; then
  echo "ERROR: inventory file not found: ${inventory_path}" >&2
  exit 1
fi

# Resolve to absolute paths
intent_abs="$(cd "$(dirname "${intent_path}")" && pwd)/$(basename "${intent_path}")"
inventory_abs="$(cd "$(dirname "${inventory_path}")" && pwd)/$(basename "${inventory_path}")"

# ============================================================
# Idempotency check
# ============================================================
if [[ -f "${output_path}" ]]; then
  intent_mtime=$(stat -c %Y "${intent_abs}" 2>/dev/null || stat -f %m "${intent_abs}" 2>/dev/null)
  inventory_mtime=$(stat -c %Y "${inventory_abs}" 2>/dev/null || stat -f %m "${inventory_abs}" 2>/dev/null)
  output_mtime=$(stat -c %Y "${output_path}" 2>/dev/null || stat -f %m "${output_path}" 2>/dev/null)

  if [[ "${output_mtime}" -ge "${intent_mtime}" && "${output_mtime}" -ge "${inventory_mtime}" ]]; then
    echo "Seed: ${output_path} is up to date (newer than inputs). Skipping regeneration."
    echo "  Intent:    ${intent_abs}"
    echo "  Inventory: ${inventory_abs}"
    exit 0
  fi
fi

# ============================================================
# Build NFM output via nix eval
# ============================================================
echo "Seed: generating NFM output..."
echo "  Intent:    ${intent_abs}"
echo "  Inventory: ${inventory_abs}"
echo "  Output:    ${output_path}"

# Determine system
system="$(nix eval --impure --expr 'builtins.currentSystem' 2>/dev/null || echo "x86_64-linux")"

# Run compiler → NFM pipeline and emit JSON
nix eval --impure --json --expr "
  let
    system = \"${system}\";
    nfmFlake = builtins.getFlake \"github:esp0xdeadbeef/network-forwarding-model\";
    nfmLib = nfmFlake.libBySystem.\"\${system}\";
    intent = import \"${intent_abs}\";
    inventory = import \"${inventory_abs}\";
    input = { inherit intent inventory; };
    nfmOutput = nfmLib.buildFromCompilerInputs { inherit input; };
  in
    # Extract the forwarding model structure (without CPM wrapper)
    nfmOutput.forwarding_model or nfmOutput
" > "${output_path}"

echo "Seed: cached NFM output written to ${output_path}"
echo "  $(wc -c < "${output_path}") bytes, $(python3 -c "import json; d=json.load(open('${output_path}')); print(len(str(d)));" 2>/dev/null || echo "?") chars"
echo "Done."
