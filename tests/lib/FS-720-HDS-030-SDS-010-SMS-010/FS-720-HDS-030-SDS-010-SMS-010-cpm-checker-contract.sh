#!/usr/bin/env bash
# GAMP-ID: FS-720-HDS-030-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# CPM Phase 3: endpointAssignment checker contract
#
# Proves P6 (DHCP/static conflict detection), P8 (bridge attachment
# validation), P10 (contract completeness). Uses hand-crafted
# endpointAssignment data — no network-labs dependency.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

cd "${repo_root}"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------
# Common Nix expression prefix (flake, lib, helpers, common)
# ---------------------------------------------------------------
PREFIX='
  let
    flake = builtins.getFlake ("path:" + toString ./.);
    system = builtins.currentSystem;
    pkgs = import flake.inputs.nixpkgs { inherit system; };
    lib = pkgs.lib;
    helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
    common = import ./src/cpm/Site/build-data/common.nix {
      inherit helpers;
      ipam = import ./src/cpm/ipam.nix { inherit lib; };
      enterpriseRoot = { };
    };
  in
'

# ---------------------------------------------------------------
# Evaluate checker with given endpointAssignment fixture
# ---------------------------------------------------------------
eval_checker() {
  local assignment="$1"
  local query="$2"
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr "
    ${PREFIX}
    let
      checker = import ./src/cpm/Site/check/endpoint-assignment-checker.nix {
        inherit helpers common;
      };
      result = checker {
        endpointAssignment = ${assignment};
      };
    in
    ${query}
  " 2>/dev/null
}

# Count diagnostics by code
count_diags() {
  local diags="$1"
  local code="$2"
  echo "$diags" | grep -o "\"${code}\"" | wc -l
}

# Assert a diagnostic with specific code exists
assert_diag_code() {
  local diags="$1"
  local code="$2"
  if echo "$diags" | grep -q "\"${code}\""; then
    pass "$3"
  else
    fail "$3 (code '$code' not found in diagnostics)"
  fi
}

# ---------------------------------------------------------------
# Test 1: Happy path — clean records, no diagnostics
# ---------------------------------------------------------------
echo "=== Test 1: Happy path — clean records (PASS) ==="

CLEAN_ASSIGNMENT='{
  "site-a-client01" = {
    name = "client01";
    tenant = "client";
    enterprise = "esp";
    site = "site-a";
    mode = "static";
    family = "dual";
    bridge = "br-client";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-client";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    static = {
      address = "10.20.20.10";
      prefixLength = 24;
      gateway4 = "10.20.20.1";
      gateway6 = "2001:db8:20:20::1";
    };
  };
  "site-a-guest01" = {
    name = "guest01";
    tenant = "guest";
    enterprise = "esp";
    site = "site-a";
    mode = "dhcp";
    family = "ipv4";
    bridge = "br-guest";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-guest";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    dhcp = {
      servedPrefix4 = "10.20.30.1/24";
      gw4 = "10.20.30.1";
      conflict = "reject-overlap";
    };
  };
}'

happy_result=$(eval_checker "$CLEAN_ASSIGNMENT" 'result.result')
happy_diags=$(eval_checker "$CLEAN_ASSIGNMENT" 'result.diagnostics')

if [ "$happy_result" = '"PASS"' ]; then
  pass "Happy path: result=PASS"
else
  fail "Happy path: result=PASS (got $happy_result)"
fi

diag_count=$(echo "$happy_diags" | grep -o '"code"' | wc -l || true)
if [ "$diag_count" -eq 0 ]; then
  pass "Happy path: 0 diagnostics"
else
  fail "Happy path: 0 diagnostics (got $diag_count)"
fi

# ---------------------------------------------------------------
# Test 2: P6 seeded negative — DHCP/static conflict on same bridge
# ---------------------------------------------------------------
echo ""
echo "=== Test 2: P6 — DHCP/static conflict on same bridge ==="

P6_ASSIGNMENT='{
  "site-a-client01" = {
    name = "client01";
    tenant = "client";
    enterprise = "esp";
    site = "site-a";
    mode = "static";
    family = "ipv4";
    bridge = "br-shared";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-client";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    static = {
      address = "10.20.20.10";
      prefixLength = 24;
      gateway4 = "10.20.20.1";
    };
  };
  "site-a-guest01" = {
    name = "guest01";
    tenant = "guest";
    enterprise = "esp";
    site = "site-a";
    mode = "dhcp";
    family = "ipv4";
    bridge = "br-shared";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-guest";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    dhcp = {
      servedPrefix4 = "10.20.20.1/24";
      gw4 = "10.20.20.1";
      conflict = "reject-overlap";
    };
  };
}'

p6_diags=$(eval_checker "$P6_ASSIGNMENT" 'result.diagnostics')
p6_result=$(eval_checker "$P6_ASSIGNMENT" 'result.result')

if [ "$p6_result" = '"FAIL"' ]; then
  pass "P6: result=FAIL (conflict detected)"
else
  fail "P6: result=FAIL (got $p6_result)"
fi

assert_diag_code "$p6_diags" "static-dhcp-conflict" "P6: static-dhcp-conflict diagnostic emitted"

if echo "$p6_diags" | grep -q '"br-shared"'; then
  pass "P6: bridge 'br-shared' in diagnostic"
else
  fail "P6: bridge 'br-shared' in diagnostic"
fi

# ---------------------------------------------------------------
# Test 3: P6 — No conflict when on different bridges
# ---------------------------------------------------------------
echo ""
echo "=== Test 3: P6 — No false conflict on different bridges ==="

SEPARATE_ASSIGNMENT='{
  "site-a-client01" = {
    name = "client01";
    tenant = "client";
    enterprise = "esp";
    site = "site-a";
    mode = "static";
    family = "ipv4";
    bridge = "br-client";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-client";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    static = {
      address = "10.20.20.10";
      prefixLength = 24;
      gateway4 = "10.20.20.1";
    };
  };
  "site-a-guest01" = {
    name = "guest01";
    tenant = "guest";
    enterprise = "esp";
    site = "site-a";
    mode = "dhcp";
    family = "ipv4";
    bridge = "br-guest";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-guest";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    dhcp = {
      servedPrefix4 = "10.20.20.1/24";
      gw4 = "10.20.20.1";
      conflict = "reject-overlap";
    };
  };
}'

separate_result=$(eval_checker "$SEPARATE_ASSIGNMENT" 'result.result')

if [ "$separate_result" = '"PASS"' ]; then
  pass "P6: No false conflict on different bridges (PASS)"
else
  fail "P6: No false conflict on different bridges (got $separate_result)"
fi

# ---------------------------------------------------------------
# Test 4: P8 seeded negative — endpoint with null bridge
# ---------------------------------------------------------------
echo ""
echo "=== Test 4: P8 — Null bridge diagnostic ==="

P8_ASSIGNMENT='{
  "site-a-client01" = {
    name = "client01";
    tenant = "client";
    enterprise = "esp";
    site = "site-a";
    mode = "static";
    family = "dual";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-client";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    static = {
      address = "10.20.20.10";
      prefixLength = 24;
      gateway4 = "10.20.20.1";
    };
  };
}'

p8_diags=$(eval_checker "$P8_ASSIGNMENT" 'result.diagnostics')
p8_result=$(eval_checker "$P8_ASSIGNMENT" 'result.result')

if [ "$p8_result" = '"FAIL"' ]; then
  pass "P8: result=FAIL (bridge missing detected)"
else
  fail "P8: result=FAIL (got $p8_result)"
fi

assert_diag_code "$p8_diags" "missing-bridge" "P8: missing-bridge diagnostic emitted"

# Also expect incomplete-record diagnostic (bridge is a required field)
assert_diag_code "$p8_diags" "incomplete-record" "P8: incomplete-record diagnostic also emitted (bridge in required fields)"

# ---------------------------------------------------------------
# Test 5: P8 — Endpoint WITH bridge passes
# ---------------------------------------------------------------
echo ""
echo "=== Test 5: P8 — Bridge present = no diagnostic ==="

BRIDGE_OK_ASSIGNMENT='{
  "site-a-client01" = {
    name = "client01";
    tenant = "client";
    enterprise = "esp";
    site = "site-a";
    mode = "static";
    family = "ipv4";
    bridge = "br-client";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-client";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    static = {
      address = "10.20.20.10";
      prefixLength = 24;
      gateway4 = "10.20.20.1";
    };
  };
}'

bridge_ok_diags=$(eval_checker "$BRIDGE_OK_ASSIGNMENT" 'result.diagnostics')

if echo "$bridge_ok_diags" | grep -q '"missing-bridge"'; then
  fail "P8: bridge present should NOT produce missing-bridge diagnostic"
else
  pass "P8: no missing-bridge diagnostic when bridge is present"
fi

# ---------------------------------------------------------------
# Test 6: P10 seeded negative — DHCP record missing servedPrefix4
# ---------------------------------------------------------------
echo ""
echo "=== Test 6: P10 — DHCP missing servedPrefix4 ==="

P10_DHCP_ASSIGNMENT='{
  "site-a-guest01" = {
    name = "guest01";
    tenant = "guest";
    enterprise = "esp";
    site = "site-a";
    mode = "dhcp";
    family = "ipv4";
    bridge = "br-guest";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-guest";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    dhcp = {
      gw4 = "10.20.30.1";
      conflict = "reject-overlap";
    };
  };
}'

p10_dhcp_diags=$(eval_checker "$P10_DHCP_ASSIGNMENT" 'result.diagnostics')
p10_dhcp_result=$(eval_checker "$P10_DHCP_ASSIGNMENT" 'result.result')

if [ "$p10_dhcp_result" = '"FAIL"' ]; then
  pass "P10 DHCP: result=FAIL (missing servedPrefix4 detected)"
else
  fail "P10 DHCP: result=FAIL (got $p10_dhcp_result)"
fi

assert_diag_code "$p10_dhcp_diags" "incomplete-record" "P10 DHCP: incomplete-record diagnostic emitted"

if echo "$p10_dhcp_diags" | grep -q 'servedPrefix4'; then
  pass "P10 DHCP: servedPrefix4 mentioned in diagnostic"
else
  fail "P10 DHCP: servedPrefix4 mentioned in diagnostic"
fi

# ---------------------------------------------------------------
# Test 7: P10 seeded negative — missing namespaceOwner
# ---------------------------------------------------------------
echo ""
echo "=== Test 7: P10 — Missing namespaceOwner ==="

P10_NS_ASSIGNMENT='{
  "site-a-client01" = {
    name = "client01";
    tenant = "client";
    enterprise = "esp";
    site = "site-a";
    mode = "static";
    family = "ipv4";
    bridge = "br-client";
    owningSubstrate = "s-router-test-clients";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    static = {
      address = "10.20.20.10";
      prefixLength = 24;
      gateway4 = "10.20.20.1";
    };
  };
}'

p10_ns_diags=$(eval_checker "$P10_NS_ASSIGNMENT" 'result.diagnostics')
p10_ns_result=$(eval_checker "$P10_NS_ASSIGNMENT" 'result.result')

if [ "$p10_ns_result" = '"FAIL"' ]; then
  pass "P10 namespace: result=FAIL (missing namespaceOwner detected)"
else
  fail "P10 namespace: result=FAIL (got $p10_ns_result)"
fi

assert_diag_code "$p10_ns_diags" "incomplete-record" "P10 namespace: incomplete-record diagnostic emitted"

if echo "$p10_ns_diags" | grep -q 'namespaceOwner'; then
  pass "P10 namespace: namespaceOwner mentioned in diagnostic"
else
  fail "P10 namespace: namespaceOwner mentioned in diagnostic"
fi

# ---------------------------------------------------------------
# Test 8: P10 — clean static record passes completeness
# ---------------------------------------------------------------
echo ""
echo "=== Test 8: P10 — Complete static record passes ==="

COMPLETE_STATIC_ASSIGNMENT='{
  "site-a-client01" = {
    name = "client01";
    tenant = "client";
    enterprise = "esp";
    site = "site-a";
    mode = "static-only";
    family = "ipv4";
    bridge = "br-client";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-client";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    static = {
      address = "10.20.20.10";
      prefixLength = 24;
      gateway4 = "10.20.20.1";
    };
  };
}'

complete_result=$(eval_checker "$COMPLETE_STATIC_ASSIGNMENT" 'result.result')

if [ "$complete_result" = '"PASS"' ]; then
  pass "P10: Complete static record passes (PASS)"
else
  fail "P10: Complete static record passes (got $complete_result)"
fi

# ---------------------------------------------------------------
# Test 9: P6 — static address inside DHCP served prefix
# ---------------------------------------------------------------
echo ""
echo "=== Test 9: P6 — Static address inside DHCP served prefix ==="

P6_CIDR_ASSIGNMENT='{
  "site-a-client01" = {
    name = "client01";
    tenant = "client";
    enterprise = "esp";
    site = "site-a";
    mode = "static";
    family = "ipv4";
    bridge = "br-shared";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-client";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    static = {
      address = "10.20.30.50";  # inside DHCP prefix 10.20.30.1/24
      prefixLength = 24;
      gateway4 = "10.20.30.1";
    };
  };
  "site-a-guest01" = {
    name = "guest01";
    tenant = "guest";
    enterprise = "esp";
    site = "site-a";
    mode = "dhcp";
    family = "ipv4";
    bridge = "br-shared";
    owningSubstrate = "s-router-test-clients";
    namespaceOwner = "site-a-access-guest";
    gampIds = [ "FS-720-HDS-030-SDS-010-SMS-010" "FS-983" ];
    dhcp = {
      servedPrefix4 = "10.20.30.1/24";
      gw4 = "10.20.30.1";
      conflict = "reject-overlap";
    };
  };
}'

p6_cidr_diags=$(eval_checker "$P6_CIDR_ASSIGNMENT" 'result.diagnostics')
p6_cidr_result=$(eval_checker "$P6_CIDR_ASSIGNMENT" 'result.result')

if [ "$p6_cidr_result" = '"FAIL"' ]; then
  pass "P6 CIDR: result=FAIL (static in DHCP prefix detected)"
else
  fail "P6 CIDR: result=FAIL (got $p6_cidr_result)"
fi

assert_diag_code "$p6_cidr_diags" "static-dhcp-conflict" "P6 CIDR: static-dhcp-conflict diagnostic emitted"

# ---------------------------------------------------------------
# Results
# ---------------------------------------------------------------
echo ""
echo "=== FS-720-HDS-030-SDS-010-SMS-010 CPM Phase 3 Checker Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Some tests FAILED."
  exit 1
else
  echo "All tests PASSED."
fi
