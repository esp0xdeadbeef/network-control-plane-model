#!/usr/bin/env bash
set -uo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
default_jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
jobs="${TEST_ASYNC_JOBS:-${default_jobs}}"

case "${jobs}" in
  ''|*[!0-9]*|0)
    echo "error: TEST_ASYNC_JOBS must be a positive integer, got '${jobs}'" >&2
    exit 2
    ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mapfile -d '' tests < <(
  find "${repo_root}/tests" -maxdepth 1 -type f -name 'test-*.sh' -print0 | sort -z
)

if ((${#tests[@]} == 0)); then
  echo "error: no tests found under ${repo_root}/tests" >&2
  exit 2
fi

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
    printf 'PASS %s\n' "${name}"
  else
    printf 'FAIL %s (exit %s)\n' "${name}" "${status}" >&2
    sed "s/^/[${name}] /" "${log_file}" >&2
    failures=$((failures + 1))
  fi
}

printf 'running %s tests with up to %s concurrent jobs\n' "${#tests[@]}" "${jobs}"

for test_path in "${tests[@]}"; do
  name="$(basename "${test_path}")"
  log_file="${tmp_dir}/${name}.log"

  bash "${test_path}" >"${log_file}" 2>&1 &
  pid=$!
  pid_to_name["${pid}"]="${name}"
  pid_to_log["${pid}"]="${log_file}"
  running=$((running + 1))
  printf 'START %s\n' "${name}"

  while ((running >= jobs)); do
    wait_for_one
  done
done

while ((running > 0)); do
  wait_for_one
done

if ((failures > 0)); then
  printf 'error: %s/%s tests failed\n' "${failures}" "${#tests[@]}" >&2
  exit 1
fi

printf 'PASS %s tests\n' "${#tests[@]}"
