#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-DNS-NO-PEER-FALLBACK-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

matches="$(
  rg \
    --no-heading \
    --line-number \
    --with-filename \
    'routeViaPeer|peerForInterface|p2p-peers' \
    "${repo_root}/src/cpm" \
    2>/dev/null || true
)"

if [[ -n "${matches}" ]]; then
  echo "FAIL no-dns-route-peer-fallback: DNS route augmentation must reuse explicit routes from NFM/realization, not synthesize p2p peer gateways" >&2
  printf '%s\n' "${matches}" >&2
  exit 1
fi

echo "PASS no-dns-route-peer-fallback"
