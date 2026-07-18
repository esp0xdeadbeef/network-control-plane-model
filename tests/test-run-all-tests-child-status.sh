#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cp "${repo_root}/run-all-tests.sh" "${tmp_dir}/run-all-tests.sh"
mkdir -p "${tmp_dir}/tests"

cat >"${tmp_dir}/tests/test-pass.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"${tmp_dir}/tests/test-fail.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF

chmod +x "${tmp_dir}/run-all-tests.sh" "${tmp_dir}/tests/"*.sh

set +e
output="$(cd "${tmp_dir}" && TEST_JOBS=1 ./run-all-tests.sh 2>&1)"
status=$?
set -e

if [[ "${status}" -eq 0 ]]; then
  echo "FAIL: run-all-tests.sh returned success despite a failing child" >&2
  exit 1
fi

grep -Fq "PASS test-pass.sh" <<<"${output}"
grep -Fq "FAIL test-fail.sh (exit 7)" <<<"${output}"
grep -Fq "Results: 1 PASS, 1 FAIL, 2 total" <<<"${output}"

set +e
invalid_output="$(cd "${tmp_dir}" && TEST_JOBS=0 ./run-all-tests.sh 2>&1)"
invalid_status=$?
set -e

if [[ "${invalid_status}" -ne 2 ]]; then
  echo "FAIL: TEST_JOBS=0 returned ${invalid_status}, expected 2" >&2
  exit 1
fi

grep -Fq "TEST_JOBS must be a positive integer" <<<"${invalid_output}"

echo "PASS: run-all-tests.sh preserves child exit status and rejects invalid concurrency"
