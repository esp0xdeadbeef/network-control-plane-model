#!/usr/bin/env bash
# GAMP-ID: FS-770-HDS-010-SDS-030-SMS-010
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-770-HDS-010-SDS-030-SMS-010.md
# OWNER:  network-control-plane-model
#
# Predicates: each accepted HAT or SAT behaviour-source shape is classified
# explicitly, and an unclassified source shape is rejected before endpoint fixture
# derivation or renderer output.
#
# EXPECTED TO FAIL, and the reason is an absence rather than a fixture problem: no
# behaviour-source-shape classifier exists in the control-plane model. The case
# states the contract and reports the gap.
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() { echo "FAIL hat-sat-source-shape-classification: $*" >&2; exit 1; }

search=( "${repo_root}/src/cpm" )

# P1 (absence claim): a behaviour-source-shape classifier must exist. The claim is
# tested over the whole control-plane model, so a single hit anywhere means the
# feature appeared and this case must be replaced with a behavioural one.
if ! grep -rqiE 'source.?shape|behavior.?source.?shape|sourceShape' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P1 no behaviour-source-shape classification exists in the control-plane model, so an unclassified HAT or SAT source shape cannot be refused before endpoint derivation"
fi

# P2: an unclassified shape must be refused, naming it.
if ! grep -rqiE 'unclassified|E_[A-Z_]*SOURCE_SHAPE|unsupported.{0,20}shape' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P2 no rejection exists for an unclassified HAT or SAT behaviour-source shape"
fi

# P3: the classification must happen before endpoint derivation, so it must be
# reachable from the site build rather than only from a debugging helper.
if ! grep -rqiE 'endpoint' "${search[@]}/Site/build-data" --include=*.nix 2>/dev/null; then
  fail "P3 there is no endpoint derivation surface to order the classification against"
fi

echo "PASS hat-sat-source-shape-classification"
