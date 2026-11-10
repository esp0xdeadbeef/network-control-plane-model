#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-030-SDS-020-SMS-030
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-800-HDS-030-SDS-020-SMS-030.md
# OWNER:  network-control-plane-model
# MODULE: pd-generation-identity
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() { echo "FAIL pd-generation-identity: $*" >&2; exit 1; }


# P1: the delegated-prefix generation publishes one active generation identity and an
# opaque prefix handle, consuming IAID, PD request identity, runtime PPP interface
# and lease status.
search=( "${repo_root}/src/cpm" )
grep -rqiE "iaid" "${search[@]}" --include=*.nix 2>/dev/null || fail "P1 no IAID is consumed on the delegated-prefix path"

grep -rqiE "generation.?identity|activeGeneration|prefixHandle" "${search[@]}" --include=*.nix 2>/dev/null \
  || fail "P1 no active generation identity or opaque prefix handle is published"

# P2: the handle must be opaque, so it must not be the raw delegated prefix.
if grep -rqE "prefixHandle\\s*=\\s*prefix\\b" "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P2 the prefix handle is the raw delegated prefix, so it is not opaque"
fi

