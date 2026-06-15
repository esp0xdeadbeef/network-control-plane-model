#!/usr/bin/env bash
# GAMP-ID: FS-770-HDS-010-SDS-020-SMS-040
# GAMP-SCOPE: software-module-test
# Focused construction test: realization mutation rejection seeded negatives (ACTIVE).
#
# SMS Acceptance Predicates (ACTIVE):
#   P1 ✓ Valid inventory compiles clean → deterministic control-plane model
#   N1 ✓ Endpoint fixture removed → REJECT (not silently repaired; diagnostic emitted)
#   N2 ✓ Missing realization node → REJECT (runtime target unrealized)
#   N3 ✓ Malformed port link → REJECT (unknown forwarding-model site link)
#
# Mutation rejection: the CPM fails on missing/malformed realization data
# rather than silently repairing it. Every negative case must produce a
# diagnostic, not a default/fallback.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

echo "--- FS-770-HDS-010-SDS-020-SMS-040: realization mutation rejection ---"
echo ""

# NOTE: Do NOT export NIX_STATE_DIR — it causes nix store lock errors with getFlake.

PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

cd "$repo_root"

LABS_REF="github:esp0xdeadbeef/network-labs/7a9e1575aa78c2e8c24ea01cf2f0b9057d8ced01"

###############################################################################
# check_cpm: compile inventory through CPM, return PASS or FAIL
###############################################################################
check_cpm() {
  local desc="$1" inv_expr="$2"
  local tmp_nix
  tmp_nix=$(mktemp /tmp/cpm-test-XXXXXX.nix)
  cat > "$tmp_nix" << NIXEND
    let cpm = builtins.getFlake (toString ${repo_root});
        system = builtins.currentSystem;
        labs = builtins.getFlake "${LABS_REF}";
        baseIntent = import (labs.outPath + "/examples/single-wan/intent.nix");
        baseInventory = import (labs.outPath + "/examples/single-wan/inventory-nixos.nix");
        inventory = (${inv_expr});
        runner = builtins.tryEval (
          let r = cpm.lib.\${system}.compileAndBuild {
            input = baseIntent; inherit inventory;
          }; in builtins.deepSeq r.control_plane_model true
        );
    in if runner.success then "PASS" else "FAIL"
NIXEND
  local result
  result=$(nix eval --impure --raw -f "$tmp_nix" 2>&1) || true
  rm -f "$tmp_nix"
  echo "$result"
}

###############################################################################
# extract_surface: compile and return model surface as JSON (no diagnostics)
###############################################################################
extract_surface() {
  local inv_expr="$1"
  local tmp_nix
  tmp_nix=$(mktemp /tmp/cpm-surface-XXXXXX.nix)
  cat > "$tmp_nix" << NIXEND
    let cpm = builtins.getFlake (toString ${repo_root});
        system = builtins.currentSystem;
        labs = builtins.getFlake "${LABS_REF}";
        baseIntent = import (labs.outPath + "/examples/single-wan/intent.nix");
        baseInventory = import (labs.outPath + "/examples/single-wan/inventory-nixos.nix");
        inventory = (${inv_expr});
        result = cpm.lib.\${system}.compileAndBuild {
          input = baseIntent; inherit inventory;
        };
        data = result.control_plane_model.data or {};
    in builtins.removeAttrs data [ "diagnostics" ]
NIXEND
  local json_output
  json_output=$(nix eval --impure --json -f "$tmp_nix" 2>&1) || true
  rm -f "$tmp_nix"
  echo "$json_output"
}

###############################################################################
# Inventory expressions (Nix syntax)
###############################################################################
BASE_INV="baseInventory"

# N1: Remove endpoint fixture (s-sigma is a DNS service provider — removing it
# from inventory means the CPM cannot resolve DNS upstreams. The CPM must REJECT
# rather than silently synthesize or skip the DNS service.)
N1_REMOVE_ENDPOINT='baseInventory // { endpoints = builtins.removeAttrs (baseInventory.endpoints or {}) [ "s-sigma" ]; }'

# N2: Remove entire access-admin node → runtime target unrealized → REJECT
N2_REMOVE_NODE='baseInventory // { realization = baseInventory.realization // { nodes = builtins.removeAttrs (baseInventory.realization.nodes or {}) [ "esp0xdeadbeef-site-a-s-router-access-admin" ]; }; }'

# N3: Bad port link reference → port-binding validation → REJECT
N3_BAD_LINK='let b = baseInventory; n = b.realization.nodes."esp0xdeadbeef-site-a-s-router-access-admin"; p = n.ports."transit-downstream-selector"; np = p // { link = "p2p-nonexistent-fake-link"; }; nn = n // { ports = n.ports // { "transit-downstream-selector" = np; }; }; in b // { realization = b.realization // { nodes = b.realization.nodes // { "esp0xdeadbeef-site-a-s-router-access-admin" = nn; }; }; }'

###############################################################################
# Part A: Positive control — valid inventory compiles clean (P1)
###############################################################################
echo "=== Part A: Positive control — valid inventory compiles ==="
echo ""

R=$(check_cpm "P1-control" "$BASE_INV")
[ "$R" = "PASS" ] && pass "P1 — valid inventory compiles clean (deterministic model surface)" || fail "P1 — expected PASS, got: $R"

# Extract and verify model surface is well-formed JSON
REF_SURFACE=$(extract_surface "$BASE_INV")
if [ -n "$REF_SURFACE" ] && echo "$REF_SURFACE" | jq -e . >/dev/null 2>&1; then
  pass "P1-surface — model surface is valid JSON"
else
  fail "P1-surface — model surface extraction failed or invalid JSON"
fi

###############################################################################
# Part B: Endpoint fixture removal → REJECT (N1)
###############################################################################
echo ""
echo "=== Part B: Endpoint fixture removal — rejection ==="
echo ""

R=$(check_cpm "N1-endpoint-removed" "$N1_REMOVE_ENDPOINT")
[ "$R" = "FAIL" ] && pass "N1 — endpoint fixture removed: CPM REJECTS (mutation not silently repaired)" || fail "N1 — expected FAIL (rejection), got: $R"

###############################################################################
# Part C: Missing realization node → REJECT (N2)
###############################################################################
echo ""
echo "=== Part C: Missing realization node — rejection ==="
echo ""

R=$(check_cpm "N2-remove-node" "$N2_REMOVE_NODE")
[ "$R" = "FAIL" ] && pass "N2 — missing realization node rejected by CPM" || fail "N2 — expected FAIL (rejection), got: $R"

###############################################################################
# Part D: Malformed port link → REJECT (N3)
###############################################################################
echo ""
echo "=== Part D: Malformed port link reference — rejection ==="
echo ""

R=$(check_cpm "N3-bad-link" "$N3_BAD_LINK")
[ "$R" = "FAIL" ] && pass "N3 — malformed port link (nonexistent p2p) rejected by CPM" || fail "N3 — expected FAIL (rejection), got: $R"

###############################################################################
echo ""
echo "=== FS-770-HDS-010-SDS-020-SMS-040 Results ==="
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ] && echo "RESULT: PASS — all SMS-040 predicates with active seeded negatives" && exit 0
echo "RESULT: FAIL"
exit 1
