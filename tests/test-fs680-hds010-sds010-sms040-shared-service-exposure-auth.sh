#!/usr/bin/env bash
# GAMP-ID: FS-680-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
# Focused construction test: shared service exposure authentication.
#
# SMS Acceptance Predicates (ACTIVE seeded negatives):
#   P1 ✓ Service with relations → builds clean
#   N1 ✓ Service with NO relations → diagnostic.missing-exposure-class
#   N2 ✓ Service with hostPlacementExposure → diagnostic.host-inferred-exposure
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

echo "--- FS-680-HDS-010-SDS-010-SMS-040: shared service exposure authentication ---"
echo ""

PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# Build helper: returns "PASS" if CPM succeeds, "FAIL" if it throws
run_check() {
  local desc="$1" intent_expr="$2"
  local result
  result=$(REPO_ROOT="$repo_root" nix eval --impure --raw --expr "
    let flake = builtins.getFlake (toString ./.); system = builtins.currentSystem;
        labs = flake.inputs.network-labs.outPath;
        baseIntent = import (labs + \"/examples/single-wan-with-nebula/intent.nix\");
        baseInventory = import (labs + \"/examples/single-wan-with-nebula/inventory-nixos.nix\");
        runner = intent: builtins.tryEval (
          let r = flake.lib.\${system}.compileAndBuild {
            input = intent; inventory = baseInventory;
          }; in builtins.deepSeq r.control_plane_model true
        );
    in if (runner (${intent_expr})).success then \"PASS\" else \"FAIL\"
  " 2>&1)
  echo "$result"
}

BASE_INTENT='baseIntent'
ADD_SVC_NO_REL='baseIntent // { esp0xdeadbeef = baseIntent.esp0xdeadbeef // { "site-a" = baseIntent.esp0xdeadbeef."site-a" // { communicationContract = (baseIntent.esp0xdeadbeef."site-a".communicationContract or {}) // { services = ((baseIntent.esp0xdeadbeef."site-a".communicationContract or {}).services or []) ++ [{ name = "n1-svc"; providers = []; trafficType = "dns"; }]; }; }; }; }'
ADD_SVC_HOST_PLACE='baseIntent // { esp0xdeadbeef = baseIntent.esp0xdeadbeef // { "site-a" = baseIntent.esp0xdeadbeef."site-a" // { communicationContract = (baseIntent.esp0xdeadbeef."site-a".communicationContract or {}) // { services = ((baseIntent.esp0xdeadbeef."site-a".communicationContract or {}).services or []) ++ [{ name = "n2-svc"; providers = []; trafficType = "dns"; hostPlacementExposure = "public"; }]; }; }; }; }'
ADD_SVC_WITH_REL='baseIntent // { esp0xdeadbeef = baseIntent.esp0xdeadbeef // { "site-a" = baseIntent.esp0xdeadbeef."site-a" // { communicationContract = (baseIntent.esp0xdeadbeef."site-a".communicationContract or {}) // { services = ((baseIntent.esp0xdeadbeef."site-a".communicationContract or {}).services or []) ++ [{ name = "clean-svc"; providers = []; trafficType = "dns"; }]; relations = ((baseIntent.esp0xdeadbeef."site-a".communicationContract or {}).relations or []) ++ [{ id = "rc"; action = "allow"; priority = 50; from = { kind = "tenant"; name = "admin"; }; to = { kind = "service"; name = "clean-svc"; }; trafficType = "dns"; }]; }; }; }; }'

# P0: Base fixture
R=$(run_check "P0" "$BASE_INTENT")
[ "$R" = "PASS" ] && pass "P0 — base fixture builds clean" || fail "P0 — $R"

# N1: Service with NO relations
R=$(run_check "N1" "$ADD_SVC_NO_REL")
[ "$R" = "FAIL" ] && pass "N1 — missing exposure class rejected" || fail "N1 — expected FAIL, got: $R"

# N2: Service with hostPlacementExposure
R=$(run_check "N2" "$ADD_SVC_HOST_PLACE")
[ "$R" = "FAIL" ] && pass "N2 — host-inferred exposure rejected" || fail "N2 — expected FAIL, got: $R"

# P1: Service with relations
R=$(run_check "P1" "$ADD_SVC_WITH_REL")
[ "$R" = "PASS" ] && pass "P1 — service with relations builds clean" || fail "P1 — expected PASS, got: $R"

echo ""
echo "=== FS-680-HDS-010-SDS-010-SMS-040 Results ==="
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ] && echo "RESULT: PASS — all SMS-040 predicates with active seeded negatives" && exit 0
echo "RESULT: FAIL"
exit 1
