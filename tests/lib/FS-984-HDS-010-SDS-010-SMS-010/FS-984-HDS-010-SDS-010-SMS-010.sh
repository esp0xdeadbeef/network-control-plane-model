#!/usr/bin/env bash
# GAMP-ID: FS-984-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

retired_trace_pattern='FS-0{2}1'

scan_retired_trace() {
  local target="$1"
  rg -n --hidden \
    --glob '!.git/**' \
    --glob '!result' \
    "${retired_trace_pattern}" \
    "${target}"
}

if findings="$(scan_retired_trace "${repo_root}")"; then
  printf 'FAIL retired dummy trace remains active:\n%s\n' "${findings}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

seeded_negative="${tmp_dir}/retired-trace.txt"
printf 'GAMP-ID: FS-%03d-HDS-%03d-SDS-%03d-SMS-%03d\n' 1 1 1 1 >"${seeded_negative}"
if ! scan_retired_trace "${seeded_negative}" >/dev/null; then
  echo 'FAIL seeded retired-trace negative was not detected' >&2
  exit 1
fi

printf 'GAMP-ID: FS-%03d-HDS-%03d-SDS-%03d-SMS-%03d\n' 984 10 10 10 >"${seeded_negative}"
if scan_retired_trace "${seeded_negative}" >/dev/null; then
  echo 'FAIL current trace recovery was rejected' >&2
  exit 1
fi

echo 'PASS FS-984 retired dummy trace rejection'
