#!/usr/bin/env bash
# GAMP-ID: FS-720-HDS-030-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# CPM Phase 1: endpointAssignment contract emission
#
# Proves P2 (DHCP records), P3 (Static records), P7 (DHCP fixture fails
# when CPM lacks required fields), P4 (no silent defaults).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
# Evaluate endpoint-assignment module with given fixture
# ---------------------------------------------------------------
eval_assignment() {
  local fixture="$1"
  local query="$2"
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr "
    ${PREFIX}
    let
      result = import ./src/cpm/Site/build-data/endpoint-assignment.nix {
        inherit lib helpers common;
        ${fixture}
      };
    in
    ${query}
  " 2>/dev/null
}

# Assert that an eval throws
eval_must_fail() {
  local fixture="$1"
  if nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr "
    ${PREFIX}
    let
      result = import ./src/cpm/Site/build-data/endpoint-assignment.nix {
        inherit lib helpers common;
        ${fixture}
      };
    in
    builtins.seq result.endpointAssignment \"should have thrown\"
  " >/dev/null 2>&1; then
    return 1
  else
    return 0
  fi
}

# ---------------------------------------------------------------
# Test 1: Static endpoint emits all P3 fields
#   Uses proper network prefix (.0/24), not host address (.1/24).
#   deriveGateway4 must produce .1 (first usable host), not .0 (network addr).
# ---------------------------------------------------------------
echo "=== Test 1: Static endpoint P3 fields ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [
      { name = "client"; kind = "tenant"; ipv4 = "10.20.20.0/24"; ipv6 = "2001:db8:20:20::/64"; }
    ];
    endpoints = [
      { name = "client01"; kind = "host"; tenant = "client"; }
    ];
  };
  inventoryEndpoints = {
    client01 = { ipv4 = [ "10.20.20.10" ]; ipv6 = [ "2001:db8:20:20::10" ]; };
  };
'

static_result=$(eval_assignment "$fixture" 'result.endpointAssignment."site-a-client01" or null')

if echo "$static_result" | grep -q '"mode".*"static"'; then
  pass "Static: mode=static"
else
  fail "Static: mode=static (got: $(echo "$static_result" | grep '"mode"' || echo 'none'))"
fi

if echo "$static_result" | grep -q '"address".*"10.20.20.10"'; then
  pass "Static: address=10.20.20.10"
else
  fail "Static: address=10.20.20.10"
fi

if echo "$static_result" | grep -q '"prefixLength".*24'; then
  pass "Static: prefixLength=24"
else
  fail "Static: prefixLength=24"
fi

if echo "$static_result" | grep -q '"gateway4".*"10.20.20.1"'; then
  pass "Static: gateway4=10.20.20.1"
else
  fail "Static: gateway4=10.20.20.1"
fi

if echo "$static_result" | grep -q '"tenant".*"client"'; then
  pass "Static: tenant=client"
else
  fail "Static: tenant=client"
fi

if echo "$static_result" | grep -q '"family".*"dual"'; then
  pass "Static: family=dual"
else
  fail "Static: family=dual"
fi

if echo "$static_result" | grep -q '"owningSubstrate".*"s-router-test-clients"'; then
  pass "Static: owningSubstrate present"
else
  fail "Static: owningSubstrate present"
fi

if echo "$static_result" | grep -q '"gampIds"'; then
  pass "Static: gampIds present"
else
  fail "Static: gampIds present"
fi

# ---------------------------------------------------------------
# Test 2: DHCP endpoint emits all P2 fields
# ---------------------------------------------------------------
echo ""
echo "=== Test 2: DHCP endpoint P2 fields ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [
      { name = "guest"; kind = "tenant"; ipv4 = "10.20.30.0/24"; ipv6 = "2001:db8:30:30::/64"; }
    ];
    endpoints = [
      { name = "guest01"; kind = "host"; tenant = "guest"; }
    ];
  };
  inventoryEndpoints = { };
'

dhcp_result=$(eval_assignment "$fixture" 'result.endpointAssignment."site-a-guest01" or null')

if echo "$dhcp_result" | grep -q '"mode".*"dhcp"'; then
  pass "DHCP: mode=dhcp"
else
  fail "DHCP: mode=dhcp (got: $(echo "$dhcp_result" | grep '"mode"' || echo 'none'))"
fi

if echo "$dhcp_result" | grep -q '"servedPrefix4".*"10.20.30.0/24"'; then
  pass "DHCP: servedPrefix4=10.20.30.0/24"
else
  fail "DHCP: servedPrefix4=10.20.30.0/24 (P2 — network prefix, not host address)"
fi

if echo "$dhcp_result" | grep -q '"gw4".*"10.20.30.1"'; then
  pass "DHCP: gw4=10.20.30.1"
else
  fail "DHCP: gw4=10.20.30.1"
fi

if echo "$dhcp_result" | grep -q '"conflict".*"reject-overlap"'; then
  pass "DHCP: conflict=reject-overlap"
else
  fail "DHCP: conflict=reject-overlap"
fi

if echo "$dhcp_result" | grep -q '"namespaceOwner".*"site-a-access-guest"'; then
  pass "DHCP: namespaceOwner=site-a-access-guest"
else
  fail "DHCP: namespaceOwner=site-a-access-guest"
fi

if echo "$dhcp_result" | grep -q '"tenant".*"guest"'; then
  pass "DHCP: tenant=guest"
else
  fail "DHCP: tenant=guest"
fi

if echo "$dhcp_result" | grep -q '"owningSubstrate".*"s-router-test-clients"'; then
  pass "DHCP: owningSubstrate present"
else
  fail "DHCP: owningSubstrate present"
fi

# ---------------------------------------------------------------
# Test 3: Mixed static+DHCP coexist
# ---------------------------------------------------------------
echo ""
echo "=== Test 3: Mixed static+DHCP endpoints ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [
      { name = "client"; kind = "tenant"; ipv4 = "10.20.20.0/24"; }
      { name = "guest"; kind = "tenant"; ipv4 = "10.20.30.0/24"; }
    ];
    endpoints = [
      { name = "client01"; kind = "host"; tenant = "client"; }
      { name = "guest01"; kind = "host"; tenant = "guest"; }
    ];
  };
  inventoryEndpoints = {
    client01 = { ipv4 = [ "10.20.20.10" ]; };
  };
'

mixed_result=$(eval_assignment "$fixture" 'builtins.attrNames result.endpointAssignment')

if echo "$mixed_result" | grep -q '"site-a-client01"'; then
  pass "Mixed: site-a-client01 present"
else
  fail "Mixed: site-a-client01 present"
fi

if echo "$mixed_result" | grep -q '"site-a-guest01"'; then
  pass "Mixed: site-a-guest01 present"
else
  fail "Mixed: site-a-guest01 present"
fi

count=$(echo "$mixed_result" | grep -o '"site-a-' | wc -l)
if [ "$count" -eq 2 ]; then
  pass "Mixed: exactly 2 records"
else
  fail "Mixed: exactly 2 records (got $count)"
fi

# ---------------------------------------------------------------
# Test 4: Seeded negative — DHCP without tenant prefix fails (P7)
# ---------------------------------------------------------------
echo ""
echo "=== Test 4: DHCP without tenant prefix FAILS (P7) ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [ ];
    endpoints = [
      { name = "orphan01"; kind = "host"; tenant = "nowhere"; }
    ];
  };
  inventoryEndpoints = { };
'

if eval_must_fail "$fixture"; then
  pass "P7: DHCP without prefix correctly fails"
else
  fail "P7: DHCP without prefix should FAIL but didn't"
fi

# ---------------------------------------------------------------
# Test 5: Seeded negative — static without addresses fails (P3)
# ---------------------------------------------------------------
echo ""
echo "=== Test 5: Static without addresses FAILS (P3) ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [
      { name = "client"; kind = "tenant"; ipv4 = "10.20.20.0/24"; }
    ];
    endpoints = [
      { name = "client01"; kind = "host"; tenant = "client"; assignment = "static"; }
    ];
  };
  inventoryEndpoints = {
    client01 = { ipv4 = [ ]; ipv6 = [ ]; };
  };
'

if eval_must_fail "$fixture"; then
  pass "P3: static without addresses correctly fails"
else
  fail "P3: static without addresses should FAIL but didn't"
fi

# ---------------------------------------------------------------
# Test 6: Non-host endpoints excluded from output
# ---------------------------------------------------------------
echo ""
echo "=== Test 6: Non-host endpoints excluded ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [
      { name = "svc"; kind = "tenant"; ipv4 = "10.20.40.1/24"; }
    ];
    endpoints = [
      { name = "svc01"; kind = "service"; tenant = "svc"; }
    ];
  };
  inventoryEndpoints = { };
'

svc_result=$(eval_assignment "$fixture" 'builtins.attrNames result.endpointAssignment')

if echo "$svc_result" | grep -q '"site-a-svc01"'; then
  fail "Non-host endpoint should be excluded but appeared in output"
else
  pass "Non-host endpoint correctly excluded"
fi

# ---------------------------------------------------------------
# Test 7: Diagnostics emitted for incomplete data
# ---------------------------------------------------------------
echo ""
echo "=== Test 7: Diagnostics for missing inventory ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [
      { name = "client"; kind = "tenant"; ipv4 = "10.20.20.0/24"; }
    ];
    endpoints = [
      { name = "client01"; kind = "host"; tenant = "client"; }
    ];
  };
  inventoryEndpoints = { };
'

diag_result=$(eval_assignment "$fixture" 'result.diagnostics')

if echo "$diag_result" | grep -q '"missing-inventory-address"'; then
  pass "Diag: missing-inventory-address emitted"
else
  fail "Diag: missing-inventory-address emitted"
fi

if echo "$diag_result" | grep -q '"FS-720-HDS-030-SDS-010-SMS-010"'; then
  pass "Diag: GAMP row ID present"
else
  fail "Diag: GAMP row ID present"
fi

# ---------------------------------------------------------------
# Test 8: Explicit assignmentMode override works
# ---------------------------------------------------------------
echo ""
echo "=== Test 8: Explicit assignmentMode ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [
      { name = "client"; kind = "tenant"; ipv4 = "10.20.20.0/24"; }
    ];
    endpoints = [
      { name = "client01"; kind = "host"; tenant = "client"; assignmentMode = "static-only"; }
    ];
  };
  inventoryEndpoints = {
    client01 = { ipv4 = [ "10.20.20.10" ]; };
  };
'

explicit_result=$(eval_assignment "$fixture" 'result.endpointAssignment."site-a-client01".mode or null')

if echo "$explicit_result" | grep -q '"static-only"'; then
  pass "Explicit: static-only respected"
else
  fail "Explicit: static-only respected (got: $explicit_result)"
fi

# ---------------------------------------------------------------
# Test 9: Seeded negative — gateway4 must be .1 not .0 (network addr)
#   This test proves FS-720-HDS-030-SDS-010-SMS-010 P3/P7 fix:
#   stripCidr("10.20.20.0/24") alone yields "10.20.20.0" which is
#   NOT a valid gateway. deriveGateway4 must produce "10.20.20.1".
# ---------------------------------------------------------------
echo ""
echo "=== Test 9: gateway4 derived as .1 not .0 (seeded negative) ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [
      { name = "client"; kind = "tenant"; ipv4 = "10.20.20.0/24"; }
    ];
    endpoints = [
      { name = "client01"; kind = "host"; tenant = "client"; }
    ];
  };
  inventoryEndpoints = {
    client01 = { ipv4 = [ "10.20.20.10" ]; };
  };
'

gw4_result=$(eval_assignment "$fixture" 'result.endpointAssignment."site-a-client01".static.gateway4 or null')

if echo "$gw4_result" | grep -q '"10.20.20.1"'; then
  pass "gateway4=10.20.20.1 (correct — first usable host, not network address)"
else
  fail "gateway4 should be 10.20.20.1 but got: $gw4_result"
fi

# Negative assertion: must NOT be the network address .0
if echo "$gw4_result" | grep -q '"10.20.20.0"'; then
  fail "REGRESSION: gateway4=10.20.20.0 — network address emitted as gateway (stripCidr bug)"
else
  pass "gateway4 is NOT 10.20.20.0 (network address correctly excluded)"
fi

# ---------------------------------------------------------------
# Test 10: IPv6 gateway6 derived as ::1 not ::0 (seeded negative)
# ---------------------------------------------------------------
echo ""
echo "=== Test 10: gateway6 derived as ::1 not ::0 (seeded negative) ==="

fixture='
  enterpriseName = "esp";
  siteName = "site-a";
  ownership = {
    prefixes = [
      { name = "client"; kind = "tenant"; ipv4 = "10.20.20.0/24"; ipv6 = "2001:db8:20:20::/64"; }
    ];
    endpoints = [
      { name = "client01"; kind = "host"; tenant = "client"; }
    ];
  };
  inventoryEndpoints = {
    client01 = { ipv4 = [ "10.20.20.10" ]; ipv6 = [ "2001:db8:20:20::10" ]; };
  };
'

gw6_result=$(eval_assignment "$fixture" 'result.endpointAssignment."site-a-client01".static.gateway6 or null')

if echo "$gw6_result" | grep -q '"2001:db8:20:20::1"'; then
  pass "gateway6=2001:db8:20:20::1 (correct — first usable host)"
else
  fail "gateway6 should be 2001:db8:20:20::1 but got: $gw6_result"
fi

# Negative assertion: must NOT be the all-zeros address
if echo "$gw6_result" | grep -q '"2001:db8:20:20::"'; then
  fail "REGRESSION: gateway6=2001:db8:20:20:: — network address emitted as gateway"
else
  pass "gateway6 is NOT 2001:db8:20:20:: (network address correctly excluded)"
fi

# ---------------------------------------------------------------
echo ""
echo "=== FS-720-HDS-030-SDS-010-SMS-010 CPM Phase 1 Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Some tests FAILED."
  exit 1
else
  echo "All tests PASSED."
fi
