#!/usr/bin/env bash
# GAMP-ID: FS-040-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NETWORK_REPO_DIRECT_TEST_OK="${NETWORK_REPO_DIRECT_TEST_OK:-}" \
  bash "${repo_root}/tests/FS-030-HDS-010-SDS-010-SMS-020-cpm-realization-binder-source-audit.sh"

NETWORK_REPO_DIRECT_TEST_OK="${NETWORK_REPO_DIRECT_TEST_OK:-}" \
  bash "${repo_root}/tests/FS-530-HDS-010-SDS-010-SMS-010-dns-resolver-advertisement-contract.sh"

echo "PASS FS-040-HDS-010-SDS-010-SMS-010 public inventory boundary"
