#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash "${repo_root}/tests/lib/nebula-provider-contract-case.sh" "${repo_root}" s-router-overlay-dns-lane-policy
