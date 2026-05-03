#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
examples_root="$(nix flake archive --json "path:${repo_root}" | jq -er '.inputs["network-labs"].path')/examples"

fail() {
  echo "$1" >&2
  exit 1
}

[[ -d "${examples_root}" ]] || fail "missing network-labs examples: ${examples_root}"

status=0

while IFS= read -r -d '' intent_path; do
  example_dir="$(dirname "${intent_path}")"
  example_name="$(basename "${example_dir}")"

  for inventory_name in inventory-clab.nix inventory-nixos.nix; do
    inventory_path="${example_dir}/${inventory_name}"
    [[ -f "${inventory_path}" ]] || continue

    output_json="$(mktemp)"
    stderr_log="$(mktemp)"

    if nix run --show-trace "path:${repo_root}#compile-and-build-control-plane-model" -- \
      "${intent_path}" \
      "${inventory_path}" \
      "${output_json}" >/dev/null 2>"${stderr_log}"; then
      echo "PASS ${example_name}/${inventory_name}"
    else
      echo "FAIL ${example_name}/${inventory_name}" >&2
      cat "${stderr_log}" >&2
      status=1
    fi

    rm -f "${output_json}" "${stderr_log}"
  done
done < <(find "${examples_root}" -mindepth 2 -maxdepth 2 -type f -name intent.nix -print0 | sort -z)

exit "${status}"
