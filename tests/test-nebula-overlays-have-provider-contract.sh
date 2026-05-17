#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

default_jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
jobs="${TEST_JOBS:-${CPM_TEST_JOBS:-${default_jobs}}}"
case "${jobs}" in
  ''|*[!0-9]*|0)
    echo "error: TEST_JOBS must be a positive integer, got '${jobs}'" >&2
    exit 2
    ;;
esac

mapfile -t tests < <(find "${repo_root}/tests/nebula-provider-contract" -maxdepth 1 -type f -name '*.sh' | sort)

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

declare -A pid_to_name=()
declare -A pid_to_log=()
running=0
failures=0

wait_for_one() {
  local finished_pid
  local status=0
  wait -n -p finished_pid || status=$?

  local name="${pid_to_name[${finished_pid}]}"
  local log_file="${pid_to_log[${finished_pid}]}"
  unset "pid_to_name[${finished_pid}]"
  unset "pid_to_log[${finished_pid}]"
  running=$((running - 1))

  if ((status == 0)); then
    tail -n 1 "${log_file}"
  else
    printf 'FAIL %s (exit %s)\n' "${name}" "${status}" >&2
    sed "s/^/[${name}] /" "${log_file}" >&2
    failures=$((failures + 1))
  fi
}

for test_path in "${tests[@]}"; do
  test_name="$(basename "${test_path}")"
  log_file="${tmp_dir}/${test_name}.log"
  bash "${test_path}" >"${log_file}" 2>&1 &
  pid=$!
  pid_to_name["${pid}"]="${test_name}"
  pid_to_log["${pid}"]="${log_file}"
  running=$((running + 1))

  while ((running >= jobs)); do
    wait_for_one
  done
done

while ((running > 0)); do
  wait_for_one
done

if ((failures > 0)); then
  printf 'error: %s/%s nebula provider contract tests failed\n' "${failures}" "${#tests[@]}" >&2
  exit 1
fi

echo "PASS nebula-overlays-have-provider-contract examples=${#tests[@]}"
