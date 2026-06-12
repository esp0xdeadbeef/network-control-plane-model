#!/usr/bin/env bash
# tests/run.sh — CPM construction test runner (auto-discovery of test-*.sh).
#
# Run individual focused tests with NETWORK_REPO_DIRECT_TEST_OK=1:
#   NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/test-fs181-hds010-sds030-sms010-realization-authority-binding.sh
#
# Run all tests:
#   bash tests/run.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== network-control-plane-model construction test sweep ==="
echo ""

# Auto-discover all test-*.sh files
tests=()
while IFS= read -r -d '' script; do
  tests+=("$script")
done < <(find "${repo_root}/tests" -maxdepth 1 -name 'test-*.sh' -print0 | sort -z)

if [ "${#tests[@]}" -eq 0 ]; then
  echo "No test-*.sh files found in tests/."
  exit 0
fi

echo "Discovered ${#tests[@]} test scripts:"
for t in "${tests[@]}"; do
  echo "  $(basename "$t")"
done
echo ""

total=0
passed=0
failed=0

for test_script in "${tests[@]}"; do
  total=$((total + 1))
  script_name="$(basename "$test_script")"
  echo "--- [$total/${#tests[@]}] ${script_name} ---"

  if NETWORK_REPO_DIRECT_TEST_OK=1 bash "$test_script" 2>&1; then
    passed=$((passed + 1))
    echo "  RESULT: PASS"
  else
    failed=$((failed + 1))
    echo "  RESULT: FAIL"
  fi
  echo ""
done

echo "=== Sweep Results: ${passed}/${total} passed, ${failed}/${total} failed ==="
if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
