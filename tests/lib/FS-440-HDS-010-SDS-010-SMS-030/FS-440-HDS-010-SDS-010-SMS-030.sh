#!/usr/bin/env bash
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-440-HDS-010-SDS-010-SMS-030.md
# OWNER:  network-control-plane-model
# MODULE: Provider Endpoint Fact Classification
#
# This case has NOT been executed. It asserts the predicates the SMS states
# against the existing classification surface; run it before changing the row.
#
# Predicates taken from the SMS:
#   P1  Provider `/32` and `/128` endpoint facts are classified as host-only or
#       overlay-participant facts unless explicit routed, delegated or translated
#       authority is modeled.
#   P2  A provider endpoint fact does not create downstream client prefix
#       authority by itself.
#
# Seeded negatives the SMS requires:
#   SN1  A provider `/32` used as client prefix authority is rejected.
#   SN2  A provider `/128` used without routed authority is rejected.
#
# To implement or fix: the surface is
# src/cpm/Site/build-data/provider-authority-classification.nix. If a seeded
# negative is not refused, the fix belongs there, not in this test.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() { echo "FAIL provider-endpoint-classification: $*" >&2; exit 1; }

surface="${repo_root}/src/cpm/Site/build-data/provider-authority-classification.nix"

if [[ ! -f "${surface}" ]]; then
  fail "P1 ${surface#"${repo_root}/"} does not exist, so provider endpoint facts are not classified anywhere"
fi

# P1: the host-only / overlay-participant classes must be expressible.
if ! grep -qiE 'hostOnly|host-only' "${surface}"; then
  fail "P1 the classification surface names no host-only class for a provider endpoint fact"
fi

# P1: explicit routed, delegated or translated authority must be recognised.
missing=""
for kind in routed delegated translated; do
  grep -qiE "${kind}" "${surface}" || missing="${missing} ${kind}"
done
if [[ -n "${missing}" ]]; then
  fail "P1 the classification surface does not recognise:${missing} authority"
fi

# P2/SN1: a provider prefix must not become downstream client authority.
if ! grep -rqiE 'downstream|clientPrefix' "${repo_root}/src/cpm/Site/build-data" --include=*.nix 2>/dev/null; then
  fail "SN1 there is no downstream/client-prefix concept to enforce the P2 separation against"
fi
if ! grep -qiE 'authority' "${surface}"; then
  fail "SN1 the classification surface carries no authority decision, so a provider prefix cannot be refused as client authority"
fi

# SN2: an IPv6 provider endpoint used without routed authority must be refused.
if ! grep -qiE 'ipv6|/128' "${surface}" && ! grep -rqiE 'ipv6' "${repo_root}/src/cpm/Site/build-data/ipv4-internet-mode.nix" 2>/dev/null; then
  fail "SN2 no IPv6 provider endpoint path exists to enforce the SN2 refusal against"
fi

echo "PASS provider-endpoint-classification"
