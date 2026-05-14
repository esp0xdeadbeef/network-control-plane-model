#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

matches="$(
  rg \
    --no-heading \
    --line-number \
    --with-filename \
    'interfaceNameHasUplinkWanPreference|interfaceNameTargetsDestination|overlayNameFromInterfaceName|accessNodeNameFromAdjacencyId|uplinkNameFromAdjacencyId|--access-|--uplink-|builtins\.match ".*--|builtins\.split "--' \
    "${repo_root}/src/cpm/Site/default-reachability" \
    "${repo_root}/src/cpm/default-reachability-model.nix" \
    2>/dev/null || true
)"

if [[ -n "${matches}" ]]; then
  echo "FAIL no-default-reachability-name-inference: default reachability must use structured lane/backingRef data, not generated interface or adjacency names" >&2
  printf '%s\n' "${matches}" >&2
  exit 1
fi

echo "PASS no-default-reachability-name-inference"
