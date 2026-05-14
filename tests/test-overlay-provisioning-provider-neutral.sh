#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

matches="$(
  rg \
    --no-heading \
    --line-number \
    --with-filename \
    --ignore-case \
    'nebula|lighthouse' \
    "${repo_root}/src/cpm/Site/build-data/overlay-provisioning.nix" \
    2>/dev/null || true
)"

if [[ -n "${matches}" ]]; then
  echo "FAIL overlay-provisioning-provider-neutral: CPM overlay provisioning must preserve provider payloads opaquely and only consume provider-neutral underlay endpoint fields" >&2
  printf '%s\n' "${matches}" >&2
  exit 1
fi

echo "PASS overlay-provisioning-provider-neutral"
