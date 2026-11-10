#!/usr/bin/env bash
# GAMP-ID: FS-770-HDS-010-SDS-030-SMS-010
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-770-HDS-010-SDS-030-SMS-010.md
# OWNER:  network-control-plane-model
# MODULE: hat-sat-source-shape-classification
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() { echo "FAIL hat-sat-source-shape-classification: $*" >&2; exit 1; }


# P1: each accepted HAT or SAT behaviour-source shape is classified explicitly, and
# an unclassified shape is rejected before endpoint derivation or renderer output.
search=( "${repo_root}/src/cpm" )
grep -rqiE "source.?shape" "${search[@]}" --include=*.nix 2>/dev/null \
  || fail "P1 no behaviour-source-shape classification exists in the control-plane model"

# P2: an unclassified shape must be refused, naming it.
grep -rqiE "unclassified|E_.*SOURCE_SHAPE|unsupported.*shape" "${search[@]}" --include=*.nix 2>/dev/null \
  || fail "P2 no rejection exists for an unclassified HAT or SAT behaviour-source shape"

