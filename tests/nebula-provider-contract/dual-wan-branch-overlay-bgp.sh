#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-NEBULA-PROVIDER-DUALWAN-BGP-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash "${repo_root}/tests/lib/nebula-provider-contract-case.sh" "${repo_root}" dual-wan-branch-overlay-bgp
