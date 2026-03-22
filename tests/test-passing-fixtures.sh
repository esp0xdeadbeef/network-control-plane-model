#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="${repo_root}/fixtures/passing"

status=0

for fixture in "${fixture_root}"/*; do
  [ -d "${fixture}" ] || continue

  output_json="$(mktemp)"
  trap 'rm -f "${output_json}"' EXIT

  expr="let input = import ${fixture}/input.nix; inventory = import ${fixture}/inventory.nix; in import ${repo_root}/src/main.nix { inherit input inventory; }"

  if ! nix eval --impure --json --expr "${expr}" >"${output_json}"; then
    echo "FAIL ${fixture}: evaluation failed"
    status=1
    rm -f "${output_json}"
    trap - EXIT
    continue
  fi

  if ! nix eval --impure --expr "
    let
      data = builtins.fromJSON (builtins.readFile ${output_json});
      cpm = data.control_plane_model or null;
    in
      builtins.isAttrs data
      && builtins.isAttrs cpm
      && (cpm.version or null) == 1
      && (cpm.source or null) == \"nix\"
      && builtins.isAttrs (cpm.data or null)
  " >/dev/null; then
    echo "FAIL ${fixture}: JSON validation failed"
    status=1
  else
    echo "PASS ${fixture}"
  fi

  rm -f "${output_json}"
  trap - EXIT
done

exit "${status}"
