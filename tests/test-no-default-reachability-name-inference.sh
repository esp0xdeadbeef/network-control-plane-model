#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-NO-DEFAULT-NAME-INFERENCE-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

matches="$(
  rg \
    --no-heading \
    --line-number \
    --with-filename \
    'interfaceNameHasUplinkWanPreference|interfaceNameTargetsDestination|overlayNameFromInterfaceName|accessNodeNameFromAdjacencyId|uplinkNameFromAdjacencyId|--access-|--uplink-|builtins\.match ".*--|builtins\.split "--' \
    "${repo_root}/src/cpm" \
    2>/dev/null || true
)"

if [[ -n "${matches}" ]]; then
  echo "FAIL no-default-reachability-name-inference: default reachability must use structured lane/backingRef data, not generated interface or adjacency names" >&2
  printf '%s\n' "${matches}" >&2
  exit 1
fi

echo "PASS no-default-reachability-name-inference"
