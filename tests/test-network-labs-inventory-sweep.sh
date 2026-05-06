#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
named_outputs_jsonl="${tmp_dir}/network-labs-outputs.jsonl"
manifest_tsv="${tmp_dir}/manifest.tsv"
violations_tsv="${tmp_dir}/violations.tsv"

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_root="$(jq -er '.inputs["network-labs"].path' "${archive_json}")"
examples_root="${labs_root}/examples"
lab_sigma_root="${labs_root}/labs/lab-s-sigma/s-router-test-three-site"

fail() {
  echo "$1" >&2
  exit 1
}

[[ -d "${examples_root}" ]] || fail "missing network-labs examples: ${examples_root}"

printf 'name\tintent\tinventory\tstatus\n' >"${manifest_tsv}"
: >"${named_outputs_jsonl}"

compile_output() {
  local name="$1"
  local intent_path="$2"
  local inventory_path="$3"
  local output_json="${tmp_dir}/${name//\//__}.json"
  local stderr_log="${tmp_dir}/${name//\//__}.stderr"

  if nix run --show-trace "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory_path}" \
    "${output_json}" >/dev/null 2>"${stderr_log}"; then
    jq -c --arg name "${name}" '{ name: $name, output: . }' "${output_json}" >>"${named_outputs_jsonl}"
    printf '%s\t%s\t%s\tOK\n' "${name}" "${intent_path}" "${inventory_path}" >>"${manifest_tsv}"
  else
    printf '%s\t%s\t%s\tCOMPILE_FAIL\n' "${name}" "${intent_path}" "${inventory_path}" >>"${manifest_tsv}"
    echo "FAIL ${name}: compile failed" >&2
    cat "${stderr_log}" >&2
    return 1
  fi
}

status=0

while IFS= read -r -d '' intent_path; do
  example_dir="$(dirname "${intent_path}")"
  example_name="$(basename "${example_dir}")"

  for inventory_name in inventory-clab.nix inventory-nixos.nix; do
    inventory_path="${example_dir}/${inventory_name}"
    [[ -f "${inventory_path}" ]] || continue

    if ! compile_output "examples/${example_name}/${inventory_name%.nix}" "${intent_path}" "${inventory_path}"; then
      status=1
    fi
  done
done < <(find "${examples_root}" -mindepth 2 -maxdepth 2 -type f -name intent.nix -print0 | sort -z)

if [[ -f "${lab_sigma_root}/intent.nix" && -f "${lab_sigma_root}/getResolvedInventory.nix" ]]; then
  for renderer in nixos clab; do
    inventory_path="${tmp_dir}/lab-s-sigma-${renderer}-resolved-inventory.nix"
    printf 'import %s/getResolvedInventory.nix { renderer = "%s"; }\n' "${lab_sigma_root}" "${renderer}" >"${inventory_path}"
    if ! compile_output "labs/lab-s-sigma/s-router-test-three-site/resolved-${renderer}" "${lab_sigma_root}/intent.nix" "${inventory_path}"; then
      status=1
    fi
  done
fi

compiled_count="$(awk -F '\t' 'NR > 1 && $4 == "OK" { count++ } END { print count + 0 }' "${manifest_tsv}")"
if ((compiled_count == 0)); then
  echo "FAIL network-labs-inventory-sweep: no network-labs outputs compiled" >&2
  exit 1
fi

: >"${violations_tsv}"
while IFS= read -r -d '' report_path; do
  jq -L "${repo_root}/tests/lib/network-labs-contracts" -r -f "${report_path}" "${named_outputs_jsonl}" >>"${violations_tsv}"
done < <(find "${repo_root}/tests/lib/network-labs-contracts" -maxdepth 1 -type f -name '*-report.jq' -print0 | sort -z)

if [[ -s "${violations_tsv}" ]]; then
  echo "FAIL network-labs-inventory-sweep: compiled output contract violations" >&2
  echo "compiled outputs:" >&2
  column -t -s "$(printf '\t')" "${manifest_tsv}" >&2
  echo "violations:" >&2
  column -t -s "$(printf '\t')" "${violations_tsv}" >&2
  exit 1
fi

if ((status != 0)); then
  echo "FAIL network-labs-inventory-sweep: one or more lab outputs failed to compile" >&2
  column -t -s "$(printf '\t')" "${manifest_tsv}" >&2
  exit "${status}"
fi

echo "PASS network-labs-inventory-sweep (${compiled_count} outputs)"
