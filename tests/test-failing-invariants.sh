#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="${repo_root}/fixtures/failing/invariants"

status=0

for fixture in "${fixture_root}"/*; do
  [ -d "${fixture}" ] || continue

  stderr_file="$(mktemp)"
  trap 'rm -f "${stderr_file}"' EXIT

  expr="let input = import ${fixture}/input.nix; inventory = import ${fixture}/inventory.nix; in import ${repo_root}/src/main.nix { inherit input inventory; }"

  if nix eval --impure --json --expr "${expr}" >/dev/null 2>"${stderr_file}"; then
    echo "FAIL ${fixture}: evaluation unexpectedly succeeded"
    status=1
  else
    expected="$(cat "${fixture}/expected-error.txt")"
    if grep -Fq "${expected}" "${stderr_file}"; then
      echo "PASS ${fixture}"
    else
      echo "FAIL ${fixture}: missing expected error"
      echo "expected: ${expected}"
      echo "stderr:"
      cat "${stderr_file}"
      status=1
    fi
  fi

  rm -f "${stderr_file}"
  trap - EXIT
done

exit "${status}"
