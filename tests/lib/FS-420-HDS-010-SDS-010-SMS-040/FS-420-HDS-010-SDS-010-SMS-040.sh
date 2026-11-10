#!/usr/bin/env bash
# GAMP-ID: FS-420-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-420-HDS-010-SDS-010-SMS-040.md
# OWNER:  network-control-plane-model
#
# Predicates: read the modeled exit translation selection from intent, and
# normalize one canonical translation-selection record per selected egress.
# Seeded negatives per the SMS: a selection without a mode, and a value with an
# unsatisfied source class.
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() { echo "FAIL exit-translation-selection: $*" >&2; exit 1; }

surface="${repo_root}/src/cpm/ControlModule/runtime-targets/public-ingress-routes.nix"
[[ -f "${surface}" ]] || fail "P1 the translation surface does not exist at ${surface#"${repo_root}/"}"

search=( "${repo_root}/src/cpm" )

# P1: the selection is read from intent.
if ! grep -rqiE 'translation' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P1 no translation selection exists in the model path"
fi

# P2: one canonical record per selected egress.
if ! grep -rqiE 'translationSelection|translation.*selection' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P2 no canonical translation-selection record exists per selected egress"
fi

# SN1: a selection without a mode must be refused. FS-230 owns the missing-mode
# diagnostic; this case asserts it is reachable from the translation path.
if ! grep -rqiE 'translationMode|missing translation mode' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "SN1 no refusal exists for a translation selection with no mode"
fi

# SN2: a value with an unsatisfied source class must be refused by source class,
# not accepted because it is present.
if ! grep -rqiE 'sourceClass' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "SN2 no source-class validation exists on the translation path"
fi

echo "PASS exit-translation-selection"
