#!/usr/bin/env bash
# GAMP-ID: FS-040-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

NETWORK_REPO_DIRECT_TEST_OK="${NETWORK_REPO_DIRECT_TEST_OK:-}" \
  bash "${repo_root}/tests/FS-030-HDS-010-SDS-010-SMS-020.sh"

NETWORK_REPO_DIRECT_TEST_OK="${NETWORK_REPO_DIRECT_TEST_OK:-}" \
  bash "${repo_root}/tests/FS-530-HDS-010-SDS-010-SMS-010.sh"

echo "PASS FS-040-HDS-010-SDS-010-SMS-010 public inventory boundary"
