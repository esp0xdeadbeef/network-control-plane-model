#!/usr/bin/env bash
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-040
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

run_case() {
  local row="$1"
  local script_path="$2"

  echo "FS440 ${row}: $(basename "${script_path}")"
  bash "${script_path}"
}

run_case "SMS-010/SMS-020" "${repo_root}/tests/test-renderer-contract-boundary.sh"
run_case "SMS-020" "${repo_root}/tests/test-overlay-provisioning-provider-neutral.sh"
run_case "SMS-030" "${repo_root}/tests/test-host-only-ipv4-upstream-contract.sh"
run_case "SMS-040" "${repo_root}/tests/test-service-exposure-classification.sh"
run_case "SMS-050" "${repo_root}/tests/test-fs250-core-role-authority-carry-through.sh"
run_case "SMS-050" "${repo_root}/tests/test-provider-bootstrap-dns-contract.sh"

echo "PASS fs440-provider-authority-rows"
