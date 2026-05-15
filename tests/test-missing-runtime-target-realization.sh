#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cp -f "${repo_root}/fixtures/passing/minimal-explicit/input.nix" "${tmp_dir}/input.nix"
cp -f "${repo_root}/fixtures/passing/minimal-explicit/inventory.nix" "${tmp_dir}/inventory.nix"

cat >"${tmp_dir}/inventory-missing-policy.nix" <<EOF
let
  base = import ${tmp_dir}/inventory.nix;
in
base // {
  realization = base.realization // {
    nodes = removeAttrs base.realization.nodes [ "policy-runtime" ];
  };
}
EOF

stderr_file="${tmp_dir}/stderr.log"

if nix run \
  --no-write-lock-file \
  --extra-experimental-features 'nix-command flakes' \
  "${repo_root}#debug" -- \
  "${tmp_dir}/input.nix" \
  "${tmp_dir}/inventory-missing-policy.nix" \
  "${tmp_dir}/out.json" \
  >/dev/null 2>"${stderr_file}"; then
  echo "FAIL missing-runtime-target-realization: unexpectedly succeeded" >&2
  exit 1
fi

if grep -qF "inventory.nix must explicitly realize every control_plane_model runtime target" "${stderr_file}" \
  && grep -qF "policy-1" "${stderr_file}"; then
  echo "PASS missing-runtime-target-realization"
else
  echo "FAIL missing-runtime-target-realization: missing expected error substring" >&2
  echo "--- stderr ---" >&2
  cat "${stderr_file}" >&2
  exit 1
fi
