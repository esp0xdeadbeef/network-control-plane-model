#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-ALL-EXAMPLES-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
named_outputs_jsonl="${tmp_dir}/network-labs-outputs.jsonl"
manifest_tsv="${tmp_dir}/manifest.tsv"
violations_tsv="${tmp_dir}/violations.tsv"
case_dir="${tmp_dir}/cases"
mkdir -p "${case_dir}"

default_jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
jobs="${TEST_JOBS:-${default_jobs}}"
if ! [[ "${jobs}" =~ ^[0-9]+$ ]] || ((jobs < 1)); then
  echo "FAIL network-labs-inventory-sweep: TEST_JOBS must be a positive integer, got '${jobs}'" >&2
  exit 2
fi

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_root="$(jq -er '.inputs["network-labs"].path' "${archive_json}")"
examples_root="${labs_root}/examples"

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
  local safe_name="${name//\//__}"
  local output_json="${case_dir}/${safe_name}.json"
  local stderr_log="${case_dir}/${safe_name}.stderr"
  local jsonl_output="${case_dir}/${safe_name}.jsonl"
  local manifest_output="${case_dir}/${safe_name}.manifest"

  if nix run --show-trace "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory_path}" \
    "${output_json}" >/dev/null 2>"${stderr_log}"; then
    jq -c --arg name "${name}" '{ name: $name, output: . }' "${output_json}" >"${jsonl_output}"
    printf '%s\t%s\t%s\tOK\n' "${name}" "${intent_path}" "${inventory_path}" >"${manifest_output}"
  else
    printf '%s\t%s\t%s\tCOMPILE_FAIL\n' "${name}" "${intent_path}" "${inventory_path}" >"${manifest_output}"
    echo "FAIL ${name}: compile failed" >&2
    cat "${stderr_log}" >&2
    return 1
  fi
}

status=0
running=0
failures=0
declare -A pid_to_name=()
declare -A pid_to_log=()

wait_for_compile() {
  local finished_pid
  local rc=0
  local name
  local log_file

  wait -n -p finished_pid || rc=$?
  name="${pid_to_name[${finished_pid}]}"
  log_file="${pid_to_log[${finished_pid}]}"
  unset "pid_to_name[${finished_pid}]"
  unset "pid_to_log[${finished_pid}]"
  running=$((running - 1))

  if ((rc != 0)); then
    failures=$((failures + 1))
    awk -v prefix="[${name}] " '{ print prefix $0 }' "${log_file}" >&2
  fi
}

while IFS= read -r -d '' intent_path; do
  example_dir="$(dirname "${intent_path}")"
  example_name="$(basename "${example_dir}")"

  for inventory_name in inventory-clab.nix inventory-nixos.nix; do
    inventory_path="${example_dir}/${inventory_name}"
    [[ -f "${inventory_path}" ]] || continue

    name="examples/${example_name}/${inventory_name%.nix}"
    log_file="${case_dir}/${name//\//__}.log"
    compile_output "${name}" "${intent_path}" "${inventory_path}" >"${log_file}" 2>&1 &
    pid_to_name[$!]="${name}"
    pid_to_log[$!]="${log_file}"
    running=$((running + 1))

    if ((running >= jobs)); then
      wait_for_compile
    fi
  done
done < <(find "${examples_root}" -mindepth 2 -maxdepth 2 -type f -name intent.nix -print0 | sort -z)

while ((running > 0)); do
  wait_for_compile
done

find "${case_dir}" -maxdepth 1 -type f -name '*.manifest' -print0 | sort -z | xargs -0 cat >>"${manifest_tsv}"
find "${case_dir}" -maxdepth 1 -type f -name '*.jsonl' -print0 | sort -z | xargs -0 cat >>"${named_outputs_jsonl}"

if ((failures != 0)); then
  status=1
fi

compiled_count="$(awk -F '\t' 'NR > 1 && $4 == "OK" { count++ } END { print count + 0 }' "${manifest_tsv}")"
if ((compiled_count == 0)); then
  echo "FAIL network-labs-inventory-sweep: no network-labs outputs compiled" >&2
  exit 1
fi

: >"${violations_tsv}"
report_failures=0
while IFS= read -r -d '' report_path; do
  if ! jq -L "${repo_root}/tests/lib/network-labs-contracts" -r -f "${report_path}" "${named_outputs_jsonl}" >>"${violations_tsv}"; then
    echo "FAIL network-labs-inventory-sweep: report $(basename "${report_path}") crashed" >&2
    report_failures=$((report_failures + 1))
  fi
done < <(find "${repo_root}/tests/lib/network-labs-contracts" -maxdepth 1 -type f -name '*-report.jq' -print0 | sort -z)

if ((report_failures != 0)); then
  exit 1
fi

if [[ -s "${violations_tsv}" ]]; then
  echo "FAIL network-labs-inventory-sweep: compiled output contract violations" >&2
  echo "compiled output summary:" >&2
  awk -F '\t' 'NR > 1 { count[$4]++ } END { for (status in count) printf "  %s\t%s\n", status, count[status] }' "${manifest_tsv}" >&2
  echo "violation summary:" >&2
  awk -F '\t' '{ count[$1]++ } END { for (kind in count) printf "  %s\t%s\n", kind, count[kind] }' "${violations_tsv}" | sort >&2
  echo "first violations:" >&2
  head -n "${NETWORK_REPO_SWEEP_VIOLATION_LIMIT:-80}" "${violations_tsv}" | column -t -s "$(printf '\t')" >&2
  if [[ "${NETWORK_REPO_SWEEP_VERBOSE:-0}" == "1" ]]; then
    echo "compiled outputs:" >&2
    column -t -s "$(printf '\t')" "${manifest_tsv}" >&2
    echo "all violations:" >&2
    column -t -s "$(printf '\t')" "${violations_tsv}" >&2
  fi
  exit 1
fi

if ((status != 0)); then
  echo "FAIL network-labs-inventory-sweep: one or more lab outputs failed to compile" >&2
  column -t -s "$(printf '\t')" "${manifest_tsv}" >&2
  exit "${status}"
fi

echo "PASS network-labs-inventory-sweep (${compiled_count} outputs)"
