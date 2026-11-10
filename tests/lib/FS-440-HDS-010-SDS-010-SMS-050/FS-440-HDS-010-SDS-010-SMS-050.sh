#!/usr/bin/env bash
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-440-HDS-010-SDS-010-SMS-050.md
# OWNER:  network-control-plane-model
#
# Predicates: runtime facts are evidence of current provider state, not authority;
# runtime facts that attempt to create policy or prefix authority are rejected.
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() { echo "FAIL runtime-facts-not-authority: $*" >&2; exit 1; }

search=( "${repo_root}/src/cpm" )

if ! grep -rqiE 'runtime.?facts?|runtimeFacts' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P1 no runtime-fact surface exists to classify as evidence rather than authority"
fi

# P1: the surface must record that runtime facts are evidence, not authority.
if ! grep -rqiE 'non.?authoritative|not.?authorit|evidence' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P1 the runtime-fact surface carries no non-authoritative/evidence classification"
fi

# P2: a runtime fact attempting to create policy or prefix authority must be
# rejected. The refusal has to name what it refused.
if ! grep -rqiE 'RUNTIME_FACT[A-Z_]*|runtime.?fact.*(reject|refuse|forbidden)|UNAUTHORIZED_BEHAVIOR_FROM_RUNTIME' \
  "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P2 no rejection exists for a runtime fact that would create policy or prefix authority"
fi

if ! grep -rqiE 'prefix.?authority' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P2 no prefix-authority concept exists to enforce the P2 separation against"
fi

echo "PASS runtime-facts-not-authority"
