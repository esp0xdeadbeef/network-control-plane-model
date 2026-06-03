#!/usr/bin/env bash
# GAMP-ID: RTM-RUNNER-CPM-NO-GUESS-001
# GAMP-SCOPE: runner-only; not SMT acceptance evidence
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

jobs="${NO_GUESSING_JOBS:-${TEST_JOBS:-4}}"
case_dir="${repo_root}/tests/no-guess-tests"
log_dir="$(mktemp -d)"
trap 'rm -rf "${log_dir}"' EXIT

mapfile -t case_files < <(find "${case_dir}" -maxdepth 1 -type f -name '*.sh' ! -name 'lib.sh' -print | sort)

if [[ "${#case_files[@]}" -eq 0 ]]; then
  echo "FAIL no-guessing: no case files found in ${case_dir}" >&2
  exit 1
fi

pids=()
logs=()
names=()

start_case() {
  local case_file="$1"
  local name
  local log_file

  name="$(basename "${case_file}")"
  log_file="${log_dir}/${name}.log"
  names+=("${name}")
  logs+=("${log_file}")

  (
    cd "${repo_root}"
    bash "${case_file}"
  ) >"${log_file}" 2>&1 &
  pids+=("$!")
}

wait_one() {
  local index="$1"
  local name="${names[$index]}"
  local log_file="${logs[$index]}"
  local status=0

  if ! wait "${pids[$index]}"; then
    status=1
  fi

  cat "${log_file}"
  if [[ "${status}" -eq 0 ]]; then
    printf 'PASS no-guess shard %s\n' "${name}"
  else
    printf 'FAIL no-guess shard %s\n' "${name}" >&2
  fi
  return "${status}"
}

status=0
next_to_wait=0

for case_file in "${case_files[@]}"; do
  start_case "${case_file}"
  if [[ "$(( ${#pids[@]} - next_to_wait ))" -ge "${jobs}" ]]; then
    if ! wait_one "${next_to_wait}"; then
      status=1
    fi
    next_to_wait=$((next_to_wait + 1))
  fi
done

while [[ "${next_to_wait}" -lt "${#pids[@]}" ]]; do
  if ! wait_one "${next_to_wait}"; then
    status=1
  fi
  next_to_wait=$((next_to_wait + 1))
done

exit "${status}"
