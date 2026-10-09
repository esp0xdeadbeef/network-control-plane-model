#!/usr/bin/env bash
set -euo pipefail

helper_path="$(readlink -f "${BASH_SOURCE[0]}")"
tests_root="$(cd "$(dirname "${helper_path}")/.." && pwd)"
repo_root="$(cd "${tests_root}/.." && pwd)"
invoked_name="$(basename "$0" .sh)"
trace_id="${1:-${invoked_name}}"
[[ "${trace_id}" == FS-*-HDS-*-SDS-*-SMS-* ]] || {
  printf 'usage: %s <trace-id>\n' "$0" >&2
  exit 2
}
case_root="${tests_root}/lib/${trace_id}"

mapfile -t cases < <(find "${case_root}" -maxdepth 1 \( -type f -o -type l \) -name '*.sh' -print | LC_ALL=C sort)
((${#cases[@]} > 0)) || {
  printf 'FAIL %s: no internal test cases found\n' "${trace_id}" >&2
  exit 1
}

for test_case in "${cases[@]}"; do
  # A retired case (fixture scenario removed upstream) is skipped, matching the
  # top-level skip convention in run-all-tests.sh. The marker stays in the file
  # so the reason remains visible and greppable.
  if grep -q '^# GAMP-SKIP: ' "${test_case}"; then
    printf 'SKIP %s: internal case %s retired (%s)\n' \
      "${trace_id}" "$(basename "${test_case}")" \
      "$(grep -m1 '^# GAMP-SKIP: ' "${test_case}" | sed 's/^# GAMP-SKIP: //')" >&2
    continue
  fi
  set +e
  case_output="$(SMS_TEST_REPO_ROOT="${repo_root}" SMS_TEST_TRACE_ID="${trace_id}" bash "${test_case}" 2>&1)"
  case_rc=$?
  set -e
  if ((case_rc != 0)); then
    printf '%s\n' "${case_output}" >&2
    printf 'FAIL %s: internal case %s exited %s without a PASS/FAIL line\n' \
      "${trace_id}" "$(basename "${test_case}")" "${case_rc}" >&2
    exit 1
  fi
  printf '%s\n' "${case_output}"
done
