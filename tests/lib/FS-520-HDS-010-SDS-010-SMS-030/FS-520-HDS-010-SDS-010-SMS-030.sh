#!/usr/bin/env bash
# GAMP-ID: FS-520-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-520-HDS-010-SDS-010-SMS-030.md
# OWNER:  network-control-plane-model
# MODULE: Route Purpose Explanation
#
# EXPECTED TO FAIL, and the failure is a spec/implementation divergence rather
# than missing plumbing. Do not widen this test to fit the current code — either
# the implementation gains the vocabulary or the divergence is resolved upstream.
#
# Predicates taken from the SMS:
#   P1  Route purpose is emitted as one of: internet, owned public service
#       prefix, remote site, exit prefix, rejected, unknown.
#   P2  Route purpose is explicit in the explanation input rather than derived
#       from a default.
#
# Requirement source: FS-520 says the function "shall identify whether the runtime
# route is being used for internet, an owned public service prefix, a remote site,
# an exit prefix, or rejected and unknown reachability."
#
# CURRENT OBSERVED STATE (static read of
# src/cpm/Site/build-data/normalize-runtime-routes.nix): `routePurpose` resolves
# to exactly two tokens, "wan-internet" for a default destination and
# "provider-prefix" otherwise:
#
#   routePurpose = intent.routePurpose or (
#     if (route.dst or null) == defaultDst family then "wan-internet"
#     else "provider-prefix");
#
# So a remote-site, exit-prefix, rejected or unknown purpose cannot be expressed,
# and the two tokens present do not match the FS vocabulary.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() { echo "FAIL route-purpose-explanation: $*" >&2; exit 1; }

surface="${repo_root}/src/cpm/Site/build-data/normalize-runtime-routes.nix"
[[ -f "${surface}" ]] || fail "P1 the runtime-route surface does not exist at ${surface#"${repo_root}/"}"

# P1: each FS-required purpose must be expressible as a routePurpose value.
# Checked individually so the failure names exactly which purposes are absent.
missing=""
for purpose in 'internet' 'owned.public.service.prefix' 'remote.site' 'exit.prefix' 'rejected' 'unknown'; do
  grep -rqiE "${purpose}" "${repo_root}/src/cpm" --include=*.nix 2>/dev/null || missing="${missing} [${purpose}]"
done

if [[ -n "${missing}" ]]; then
  fail "P1 route purpose cannot express:${missing}.
FS-520 requires internet, owned public service prefix, remote site, exit prefix,
rejected and unknown. The implementation currently resolves routePurpose to only
'wan-internet' and 'provider-prefix', so four of the six FS categories are
unrepresentable and the two that exist use a vocabulary the FS does not name."
fi

# P2: the purpose must be explicit input, not only a computed default. The code
# honours `intent.routePurpose or (...)`; assert the explicit form is present so a
# reader can supply it.
if ! grep -qE 'intent\.routePurpose' "${surface}"; then
  fail "P2 routePurpose is not accepted as explicit explanation input"
fi

echo "PASS route-purpose-explanation"
