#!/usr/bin/env bash
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# Focused construction test: provider profile classification seeded negatives (ACTIVE).
#
# SMS Acceptance Predicates (ACTIVE):
#   P1 ✓ Well-formed profile → valid ProviderProfileClassification
#   N1 ✓ Missing/empty upstreamType → eval fails (ACTIVE rejection by CPM)
#   N2 ✓ ipv4Mode=routed-public with nat44≠none → eval fails (ACTIVE conflict check)
#   N3 ✓ Commercial VPN with publicIngress=true → eval fails (ACTIVE authority check)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

echo "--- FS-440-HDS-010-SDS-010-SMS-010: provider classification seeded negatives ---"
echo ""

PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

run_check() {
  local desc="$1" intent_expr="$2"
  local result
  result=$(REPO_ROOT="$repo_root" nix eval --impure --raw --expr "
    let flake = builtins.getFlake (toString ./.); system = builtins.currentSystem;
        labs = flake.inputs.network-labs.outPath;
        baseIntent = import (labs + \"/examples/single-wan-with-nebula/intent.nix\");
        baseInventory = import (labs + \"/examples/single-wan-with-nebula/inventory-nixos.nix\");
        runner = inventory: builtins.tryEval (
          let r = flake.lib.\${system}.compileAndBuild {
            input = baseIntent; inventory = inventory;
          }; in builtins.deepSeq r.control_plane_model true
        );
    in if (runner (${intent_expr})).success then \"PASS\" else \"FAIL\"
  " 2>&1)
  echo "$result"
}

# Well-formed provider profile with all required fields
POSITIVE_INV='baseInventory // { controlPlane = baseInventory.controlPlane // { sites = baseInventory.controlPlane.sites // { esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // { "site-a" = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a" or {}) // { overlays = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays or {}) // { nebula = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays.nebula or {}) // { providerAuthority = { upstreamType = "overlay-egress"; providerTechnology = "nebula"; ipv4Mode = "overlay-host-only"; ipv6Mode = "overlay-host-only"; prefixAuthority = { routedClient = false; delegated = false; translated = false; source = "provider-authority-record"; }; dnsFollowSource = { enabled = true; source = "provider-authority-record"; }; publicIngress = { allowed = false; source = "provider-authority-record"; }; routeAuthority = { import = false; export = false; source = "provider-authority-record"; }; nat = { nat44 = "none"; nat66 = "none"; }; failureBehavior = "fail-closed"; expectedClientEgress = "overlay-underlay-bootstrap-only"; wanEgressRelationship = "policy-selected-uplink-nebula"; runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = false; }; }; }; }; }; }; }; }; }'

# N1: Empty upstreamType
MISSING_UPSTREAM_INV='baseInventory // { controlPlane = baseInventory.controlPlane // { sites = baseInventory.controlPlane.sites // { esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // { "site-a" = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a" or {}) // { overlays = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays or {}) // { nebula = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays.nebula or {}) // { providerAuthority = { upstreamType = ""; providerTechnology = "nebula"; ipv4Mode = "overlay-host-only"; ipv6Mode = "overlay-host-only"; prefixAuthority = { routedClient = false; delegated = false; translated = false; source = "provider-authority-record"; }; dnsFollowSource = { enabled = false; source = "provider-authority-record"; }; publicIngress = { allowed = false; source = "provider-authority-record"; }; routeAuthority = { import = false; export = false; source = "provider-authority-record"; }; nat = { nat44 = "none"; nat66 = "none"; }; failureBehavior = "fail-closed"; expectedClientEgress = "undefined"; wanEgressRelationship = "undefined"; runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = false; }; }; }; }; }; }; }; }; }'

# N2: ipv4Mode=routed-public with nat44=napt44 (conflict)
CONFLICT_INV='baseInventory // { controlPlane = baseInventory.controlPlane // { sites = baseInventory.controlPlane.sites // { esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // { "site-a" = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a" or {}) // { overlays = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays or {}) // { nebula = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays.nebula or {}) // { providerAuthority = { upstreamType = "overlay-egress"; providerTechnology = "nebula"; ipv4Mode = "routed-public"; ipv6Mode = "none"; prefixAuthority = { routedClient = true; delegated = false; translated = false; source = "provider-authority-record"; }; dnsFollowSource = { enabled = false; source = "provider-authority-record"; }; publicIngress = { allowed = false; source = "provider-authority-record"; }; routeAuthority = { import = false; export = false; source = "provider-authority-record"; }; nat = { nat44 = "napt44"; nat66 = "none"; }; failureBehavior = "fail-closed"; expectedClientEgress = "routed-public"; wanEgressRelationship = "direct-uplink"; runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = false; }; }; }; }; }; }; }; }; }'

# N3: Commercial VPN with publicIngress=true
VPN_PUBLIC_INV='baseInventory // { controlPlane = baseInventory.controlPlane // { sites = baseInventory.controlPlane.sites // { esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // { "site-a" = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a" or {}) // { overlays = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays or {}) // { nebula = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays.nebula or {}) // { provider = "commercial-vpn"; providerAuthority = { upstreamType = "commercial-vpn"; providerTechnology = "wireguard-commercial-vpn"; ipv4Mode = "overlay-host-only"; ipv6Mode = "overlay-host-only"; prefixAuthority = { routedClient = false; delegated = false; translated = false; source = "provider-authority-record"; }; dnsFollowSource = { enabled = false; source = "provider-authority-record"; }; publicIngress = { allowed = true; source = "provider-authority-record"; }; routeAuthority = { import = false; export = false; source = "provider-authority-record"; }; nat = { nat44 = "none"; nat66 = "none"; }; failureBehavior = "fail-closed"; expectedClientEgress = "portable-egress"; wanEgressRelationship = "portable-egress-no-public-ingress"; runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = false; }; }; }; }; }; }; }; }; }'

# P1: Well-formed profile passes
R=$(run_check "P1" "$POSITIVE_INV")
[ "$R" = "PASS" ] && pass "P1 — well-formed profile builds clean" || fail "P1 — $R"

# N1: Missing/empty upstreamType → rejection
R=$(run_check "N1" "$MISSING_UPSTREAM_INV")
[ "$R" = "FAIL" ] && pass "N1 — missing upstreamType rejected" || fail "N1 — expected FAIL, got: $R"

# N2: ipv4/nat conflict → rejection
R=$(run_check "N2" "$CONFLICT_INV")
[ "$R" = "FAIL" ] && pass "N2 — ipv4Mode/natMode conflict rejected" || fail "N2 — expected FAIL, got: $R"

# N3: Commercial VPN with publicIngress=true → rejection
R=$(run_check "N3" "$VPN_PUBLIC_INV")
[ "$R" = "FAIL" ] && pass "N3 — commercial VPN publicIngress rejected" || fail "N3 — expected FAIL, got: $R"

echo ""
echo "=== FS-440-HDS-010-SDS-010-SMS-010 Results ==="
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ] && echo "RESULT: PASS — all SMS-010 predicates with active seeded negatives" && exit 0
echo "RESULT: FAIL"
exit 1
