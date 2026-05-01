#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

labs_root="$(flake_input_path network-labs)"
case_dir="${labs_root}/examples/single-wan"

intent_path="${case_dir}/intent.nix"
inventory_path="${case_dir}/inventory-nixos.nix"

if [[ ! -f "${intent_path}" ]]; then
  echo "missing intent.nix at ${intent_path}" >&2
  exit 1
fi
if [[ ! -f "${inventory_path}" ]]; then
  echo "missing inventory-nixos.nix at ${inventory_path}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cp -f "${intent_path}" "${tmp_dir}/intent.nix"
cp -f "${inventory_path}" "${tmp_dir}/inventory-nixos.nix"
chmod u+w "${tmp_dir}/inventory-nixos.nix"

# Break exactly one required dedicated-lane port realization:
# downstream-selector <-> policy lane for access-client.
(cd "${tmp_dir}" && python3 - <<'PY'
from pathlib import Path

p = Path("inventory-nixos.nix")
text = p.read_text()

old = '"link":"p2p-s-router-downstream-selector-s-router-policy--access-s-router-access-client"'
new = '"link":"p2p-s-router-downstream-selector-s-router-policy--access-s-router-access-client--BROKEN"'

if old not in text:
    raise SystemExit("expected lane link string not found in inventory-nixos.nix")

text = text.replace(
    old,
    new,
    1,
)
p.write_text(text)
PY
)

stderr_file="${tmp_dir}/stderr.log"

if nix run \
  --no-write-lock-file \
  --extra-experimental-features 'nix-command flakes' \
  "${repo_root}#compile-and-build-control-plane-model" -- \
  "${tmp_dir}/intent.nix" \
  "${tmp_dir}/inventory-nixos.nix" \
  "${tmp_dir}/out.json" \
  >/dev/null 2>"${stderr_file}"; then
  echo "FAIL missing-lane-binding: unexpectedly succeeded" >&2
  exit 1
fi

if grep -qF "requires explicit port realization" "${stderr_file}"; then
  echo "PASS missing-lane-binding"
else
  echo "FAIL missing-lane-binding: missing expected error substring" >&2
  echo "--- stderr ---" >&2
  cat "${stderr_file}" >&2
  exit 1
fi
