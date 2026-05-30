#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

cd "${repo_root}"

state_eval_expr() {
  local attr="$1"
  printf '(import ./tests/state-contracts/cases.nix).%s\n' "${attr}"
}

state_assert_true() {
  local attr="$1"
  local label="$2"
  if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$(state_eval_expr "${attr}")" | grep -qx true; then
    printf 'PASS %s\n' "${label}"
  else
    printf 'FAIL %s\n' "${label}" >&2
    exit 1
  fi
}

state_assert_fails() {
  local attr="$1"
  local expected="$2"
  local label="$3"
  local tmp
  tmp="$(mktemp)"
  if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$(state_eval_expr "${attr}")" >"${tmp}.out" 2>"${tmp}.err"; then
    printf 'FAIL %s: expression unexpectedly evaluated\n' "${label}" >&2
    rm -f "${tmp}" "${tmp}.out" "${tmp}.err"
    exit 1
  fi
  if ! rg -q "${expected}" "${tmp}.err"; then
    printf 'FAIL %s: expected diagnostic not found: %s\n' "${label}" "${expected}" >&2
    cat "${tmp}.err" >&2
    rm -f "${tmp}" "${tmp}.out" "${tmp}.err"
    exit 1
  fi
  rm -f "${tmp}" "${tmp}.out" "${tmp}.err"
  printf 'PASS %s\n' "${label}"
}
