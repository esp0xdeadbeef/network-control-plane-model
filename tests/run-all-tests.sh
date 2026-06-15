#!/usr/bin/env bash
# run-all-tests.sh — Discover and run all CPM construction tests.
# Auto-discovers via test-*.sh and FS-*.sh globs in tests/.
# Usage:
#   NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/run-all-tests.sh
#   NETWORK_REPO_SWEEP=1 bash tests/run-all-tests.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NETWORK_REPO_DIRECT_TEST_OK="${NETWORK_REPO_DIRECT_TEST_OK:-1}"

cd "${repo_root}"

total=0
passed=0
failed=0

echo "=== CPM Construction Tests ==="
echo ""

# Auto-discover: test-*.sh and FS-*.sh
for test_file in tests/test-*.sh tests/FS-*.sh; do
  [[ -f "${test_file}" ]] || continue
  total=$((total + 1))
  test_name="$(basename "${test_file}" .sh)"

  echo -n "  ${test_name} ... "
  if bash "${test_file}" >/dev/null 2>&1; then
    echo "PASS"
    passed=$((passed + 1))
  else
    echo "FAIL"
    failed=$((failed + 1))
  fi
done

echo ""
echo "=== Results: ${passed}/${total} PASS, ${failed}/${total} FAIL ==="
[[ "${failed}" -eq 0 ]] || exit 1
