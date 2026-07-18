#!/usr/bin/env bash
# run-all-tests.sh — Run all CPM construction tests with auto-discovery.
#
# Discovers all test-*.sh and FS-*.sh files under tests/, runs each in a background
# subprocess, captures output, and reports PASS/FAIL per test.
#
# Sets NETWORK_REPO_DIRECT_TEST_OK=1 so that CPM direct tests pass the
# repo-spot-test guard. Tests that need NETWORK_REPO_SWEEP=1 should be
# run through the full-network sweep infrastructure instead.
#
# Usage:
#   ./run-all-tests.sh
#
# Exit: 0 if all tests pass, 1 if any test fails.
set -euo pipefail
exec > >(tee "/tmp/network-control-plane-model-tests.out")

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Auto-discover tests
# ============================================================
tests=()
for f in "${repo_root}/tests/test-"*.sh "${repo_root}/tests/FS-"*.sh; do
  [[ -f "${f}" ]] || continue
  tests+=("${f}")
done

if [[ "${#tests[@]}" -eq 0 ]]; then
  echo "ERROR: no test-*.sh files found under ${repo_root}/tests/" >&2
  exit 2
fi

# ============================================================
# Run all tests asynchronously
# ============================================================
test_jobs="${TEST_JOBS:-$(nproc)}"
if [[ ! "${test_jobs}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: TEST_JOBS must be a positive integer, got '${test_jobs}'" >&2
  exit 2
fi

echo "Running ${#tests[@]} CPM tests (async, up to ${test_jobs} jobs)..."
echo ""

# Collect PIDs and names
declare -A pid_to_name=()
declare -A pid_to_log=()
active_pids=()

passes=0
failures=0

collect_pid() {
  local pid="$1"
  local name="${pid_to_name[${pid}]}"
  local log_file="${pid_to_log[${pid}]}"
  local status

  # Wait for this specific PID without letting `set -e` abort the collector.
  # The status must come from the child itself; `wait ... || true` would turn
  # every failing child into status 0 and make the full suite false-green.
  if wait "${pid}" 2>/dev/null; then
    status=0
  else
    status=$?
  fi

  if [[ "${status}" -eq 0 ]]; then
    echo "PASS ${name}"
    passes=$((passes + 1))
  else
    echo "FAIL ${name} (exit ${status})"
    echo "--- ${name} output (last 20 lines) ---"
    tail -20 "${log_file}" 2>/dev/null || true
    echo "--- end ${name} ---"
    echo ""
    failures=$((failures + 1))
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

for test_path in "${tests[@]}"; do
  name="$(basename "${test_path}")"
  log_file="${tmp_dir}/${name}.log"

  # Run test in background with NETWORK_REPO_DIRECT_TEST_OK=1
  NETWORK_REPO_DIRECT_TEST_OK=1 bash "${test_path}" >"${log_file}" 2>&1 &
  pid=$!
  pid_to_name["${pid}"]="${name}"
  pid_to_log["${pid}"]="${log_file}"
  active_pids+=("${pid}")

  if [[ "${#active_pids[@]}" -ge "${test_jobs}" ]]; then
    collect_pid "${active_pids[0]}"
    active_pids=("${active_pids[@]:1}")
  fi
done

# ============================================================
# Wait for all tests and collect results
# ============================================================
for pid in "${active_pids[@]}"; do
  collect_pid "${pid}"
done

# ============================================================
# Report
# ============================================================
echo ""
echo "Results: ${passes} PASS, ${failures} FAIL, $((passes + failures)) total"
printf 'PASS: %s, FAIL: %s, TOTAL: %s\n' "${passes}" "${failures}" "$((passes + failures))" >&2

if [[ "${failures}" -gt 0 ]]; then
  exit 1
fi

exit 0
