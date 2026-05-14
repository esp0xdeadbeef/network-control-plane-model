#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

matches="$(
  rg \
    --no-heading \
    --line-number \
    --with-filename \
    'routeViaPeer|peerForInterface|p2p-peers' \
    "${repo_root}/src/cpm/ControlModule/route-augmentation/dns" \
    "${repo_root}/src/cpm/ControlModule/runtime-targets/dns-contracts.nix" \
    2>/dev/null || true
)"

if [[ -n "${matches}" ]]; then
  echo "FAIL no-dns-route-peer-fallback: DNS route augmentation must reuse explicit routes from NFM/realization, not synthesize p2p peer gateways" >&2
  printf '%s\n' "${matches}" >&2
  exit 1
fi

echo "PASS no-dns-route-peer-fallback"
