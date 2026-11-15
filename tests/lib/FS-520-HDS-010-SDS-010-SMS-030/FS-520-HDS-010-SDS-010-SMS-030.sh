#!/usr/bin/env bash
# GAMP-ID: FS-520-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-520-HDS-010-SDS-010-SMS-030.md
# OWNER:  network-control-plane-model
# MODULE: Route Purpose Emission
#
# Predicates:
#   P1  The emitted purpose is one of the FS-520 set: internet,
#       owned-public-service-prefix, remote-site, exit-prefix, rejected, unknown.
#   P2  A purpose the producer declared is carried unchanged; only the two the
#       route itself determines are derived (default -> internet,
#       runtime-learned non-default -> exit-prefix).
#   P3  A producer value outside the set fails closed instead of being emitted.
#
# The classifier is exercised directly, not by grepping the source: the former
# version of this case only searched `src/cpm` for the vocabulary strings, so a
# comment containing the words satisfied it and neither the derivation nor the
# rejection was ever evaluated.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() { echo "FAIL route-purpose-emission: $*" >&2; exit 1; }

out="$(REPO_ROOT="${repo_root}" nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    lib = flake.inputs.nixpkgs.lib;
    normalizer = import (builtins.getEnv "REPO_ROOT" + "/src/cpm/Site/build-data/normalize-runtime-routes.nix") {
      inherit lib;
      common = {
        attrsOrEmpty = value: if builtins.isAttrs value then value else { };
        listOrEmpty = value: if builtins.isList value then value else [ ];
      };
    };
    classify = normalizer.classifyRoutePurpose;
    values = normalizer.routePurposeVocabulary;
    succeeds = expression: (builtins.tryEval expression).success;
    learned = { dst = "198.51.100.0/24"; };
  in {
    vocabulary = values;
    default4 = classify 4 { dst = "0.0.0.0/0"; } { };
    default6 = classify 6 { dst = "::/0"; } { };
    learned = classify 4 learned { };
    declared = map (purpose: classify 4 learned { routePurpose = purpose; }) values;
    explicitBeatsDerivation = classify 4 { dst = "0.0.0.0/0"; } { routePurpose = "remote-site"; };
    legacyWanInternet = succeeds (classify 4 learned { routePurpose = "wan-internet"; });
    legacyProviderPrefix = succeeds (classify 4 learned { routePurpose = "provider-prefix"; });
  }')"

jq -e '
  .vocabulary == [
    "internet",
    "owned-public-service-prefix",
    "remote-site",
    "exit-prefix",
    "rejected",
    "unknown"
  ]
' <<<"${out}" >/dev/null || fail "P1 the closed purpose vocabulary is not the FS-520 set: $(jq -c '.vocabulary' <<<"${out}")"

jq -e '.default4 == "internet" and .default6 == "internet"' <<<"${out}" >/dev/null \
  || fail "P2 a default route did not classify as internet: $(jq -c '{default4,default6}' <<<"${out}")"

jq -e '.learned == "exit-prefix"' <<<"${out}" >/dev/null \
  || fail "P2 a runtime-learned non-default route did not classify as exit-prefix: $(jq -c '.learned' <<<"${out}")"

jq -e '.declared == .vocabulary' <<<"${out}" >/dev/null \
  || fail "P2 a declared purpose was not carried unchanged: $(jq -c '.declared' <<<"${out}")"

jq -e '.explicitBeatsDerivation == "remote-site"' <<<"${out}" >/dev/null \
  || fail "P2 an explicit purpose was overwritten by the default derivation"

if jq -e '.legacyWanInternet or .legacyProviderPrefix' <<<"${out}" >/dev/null; then
  fail "P3 a producer purpose outside the FS-520 set was accepted (expected a fail-closed rejection)"
fi

echo "PASS route-purpose-emission"
