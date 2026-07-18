#!/usr/bin/env bash
# GAMP-ID: FS-450-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-450-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-450-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

run_case() {
  local row="$1"
  local script_path="$2"

  echo "FS450 ${row}: $(basename "${script_path}")"
  bash "${script_path}"
}

run_case "SMS-010" "${repo_root}/tests/test-public-overlay-service-binding.sh"
run_case "SMS-010/SMS-030" "${repo_root}/tests/FS-190-HDS-010-SDS-010-SMS-010-service-exposure-classification.sh"
run_case "SMS-010/SMS-030" "${repo_root}/tests/test-service-provider-endpoints.sh"
run_case "SMS-020" "${repo_root}/tests/test-routed-public-ipv6-contract.sh"
run_case "SMS-020" "${repo_root}/tests/FS-400-HDS-010-SDS-010-SMS-040-overlay-client-gua-mode-contract.sh"
run_case "SMS-030" "${repo_root}/tests/test-provider-bootstrap-dns-contract.sh"
run_case "SMS-030" "${repo_root}/tests/FS-250-HDS-010-SDS-010-SMS-010-fs250-core-role-authority-carry-through.sh"

echo "PASS fs450-provider-profile-authority-rows"
