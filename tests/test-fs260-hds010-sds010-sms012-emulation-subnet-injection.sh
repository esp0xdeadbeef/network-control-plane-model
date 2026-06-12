#!/usr/bin/env bash
# GAMP-ID: FS-260-HDS-010-SDS-010-SMS-012
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM emulation subnet injection into fabricSubnets.
#
# SMS Acceptance Predicates covered (5 of 8):
#   P1 ✓ Emulation subnets included in fabricSubnets alongside tenant/transit
#   P2 ✓ Without emulation subnets, fabricSubnets = tenant + transit only
#   P3 ✓ Emulation subnets are additive (tenant/transit counts preserved)
#   P4 ✓ fabricSubnetSources tracks emulation/tenant/transit counts
#   P5 ✓ Emulation subnet overlapping with tenant is deduplicated
#
# SMS Predicates NOT YET covered (implementation gaps):
#   P6 ✗ Non-production guard: diagnostic + rejection when guard missing
#   P7 ✗ Conflict detection: diagnostic when overlap with modeled topology
#   P8 ✗ Provenance tagging on individual artifacts (source="emulation")
#   → These require CPM implementation of guard/conflict/tagging modules.
#   → See SMS Seeded Negatives 1-3 in FS-260-HDS-010-SDS-010-SMS-012.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
all_checks_passed=true

echo "--- FS-260-HDS-010-SDS-010-SMS-012: CPM emulation subnet injection ---"
echo ""

# Base mock args shared across all tests
BASE_ARGS='
  accessAdvertisements = null; accessSpaceDiscovery = null; attachments = [];
  bgpSiteAsn = null; bgpTopology = null; communicationContract = null; coreNodeNames = [];
  domainsValue = { tenants = { t1 = { ipv4 = "10.20.0.0/24"; }; }; };
  endpointAssignment = null; forwardingSemantics = {};
  ipv4InternetMode = {}; ipv6Plan = null;
  overlayClientGuaMode = { records = []; diagnostics = []; };
  overlayProvisioning = {}; policyAttrs = {}; policyEndpointBindings = { relations = []; interfaceTags = {}; };
  policyNodeName = "policy"; rendererContracts = {};
  routedClientGuaMode = { records = []; diagnostics = []; };
  routedPrefixesByTenant = {}; routingMode = "static"; runtimeTargets = {}; services = {};
  siteAttrs = {}; siteDisplayName = "test"; siteId = "test"; tenantPrefixOwners = {};
  trafficPaths = [];
  transitAttrs = { adjacencies = [ { endpoints = [ { local = { ipv4 = "10.0.0.1/31"; }; } ]; } ]; };
  uplinkCoreNames = []; uplinkNames = []; uplinkRouting = {};
  upstreamSelectorNodeName = "upstream";
  ulaNat66Mode = { records = { ulaNat66 = []; }; diagnostics = { ulaNat66 = []; }; };
'

nix_eval() {
  local desc="$1" args="$2" apply="$3" expected="$4"
  local result
  result=$(REPO_ROOT="${repo_root}" nix eval --impure --expr "
    let lib = import <nixpkgs/lib>; in
    import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Site/build-data/output.nix\") {
      inherit lib; isNonEmptyString = s: builtins.isString s && s != \"\"; ${args}
    }
  " --apply "${apply}" 2>/dev/null || echo "__ERROR__")

  if [[ "${result}" == "${expected}" ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} — expected '${expected}', got '${result}'"
    all_checks_passed=false
  fi
}

# ── P1: Emulation subnets included in fabricSubnets ──
nix_eval "P1a: 10.11.0.0/24 in fabricSubnets" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" \"198.51.100.0/24\" ];" \
  'o: builtins.elem "10.11.0.0/24" o.fabricSubnets' \
  "true"

nix_eval "P1b: 198.51.100.0/24 in fabricSubnets" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" \"198.51.100.0/24\" ];" \
  'o: builtins.elem "198.51.100.0/24" o.fabricSubnets' \
  "true"

nix_eval "P1c: fabricSubnets includes all 3 categories" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" ];" \
  'o: builtins.length o.fabricSubnets' \
  "3"

# ── P2: No emulation → only tenant + transit ──
nix_eval "P2a: default fabricSubnets length = 2 (tenant + transit)" \
  "${BASE_ARGS}" \
  'o: builtins.length o.fabricSubnets' \
  "2"

nix_eval "P2b: tenant subnet present without emulation" \
  "${BASE_ARGS}" \
  'o: builtins.elem "10.20.0.0/24" o.fabricSubnets' \
  "true"

# ── P3: Emulation is additive — tenant/transit counts preserved ──
nix_eval "P3a: tenantCount = 1 with emulation" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" ];" \
  'o: o.fabricSubnetSources.tenantCount' \
  "1"

nix_eval "P3b: transitCount = 1 with emulation" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" ];" \
  'o: o.fabricSubnetSources.transitCount' \
  "1"

nix_eval "P3c: tenant subnet present with emulation" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" ];" \
  'o: builtins.elem "10.20.0.0/24" o.fabricSubnets' \
  "true"

# ── P4: fabricSubnetSources tracks counts ──
nix_eval "P4a: emulationCount = 2" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" \"198.51.100.0/24\" ];" \
  'o: o.fabricSubnetSources.emulationCount' \
  "2"

nix_eval "P4b: emulationCount = 0 when empty" \
  "${BASE_ARGS} emulationSubnets = [];" \
  'o: o.fabricSubnetSources.emulationCount' \
  "0"

nix_eval "P4c: fabricSubnetSources has all 3 keys" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" ];" \
  'o: builtins.attrNames o.fabricSubnetSources' \
  '[ "emulationCount" "tenantCount" "transitCount" ]'

# ── P5: Deduplication — overlap with tenant → counted once ──
nix_eval "P5a: duplicate subnet counted once in fabricSubnets" \
  "${BASE_ARGS} emulationSubnets = [ \"10.20.0.0/24\" ];" \
  'o: builtins.length o.fabricSubnets' \
  "2"

nix_eval "P5b: duplicate subnet not double-counted in emulationCount" \
  "${BASE_ARGS} emulationSubnets = [ \"10.20.0.0/24\" ];" \
  'o: o.fabricSubnetSources.emulationCount' \
  "1"

# ── Gap markers: SMS predicates NOT covered ──
echo ""
echo "--- SMS Coverage Gap Report ---"
echo "GAP-NG1: Non-production guard diagnostic — NOT IMPLEMENTED in output.nix"
echo "  SMS requires: diagnostic.emulation-subnet-missing-production-guard when guard absent"
echo "GAP-NG2: Conflict detection diagnostic — NOT IMPLEMENTED in output.nix"
echo "  SMS requires: diagnostic.emulation-subnet-conflicts-with-model on overlap"
echo "GAP-NG3: Provenance tagging per-artifact — NOT IMPLEMENTED in output.nix"
echo "  SMS requires: source=\"emulation\" tag on routes/rules/entries"
echo "  (fabricSubnetSources.emulationCount is present but tags individual artifacts)"
echo "---"

echo ""
if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS: FS-260-HDS-010-SDS-010-SMS-012 (12/12 assertions, 5/8 SMS predicates)"
  echo "NOTE: 3 seeded-negative predicates blocked on CPM implementation gaps (NG1-NG3)"
  exit 0
else
  echo "FAIL: One or more checks failed."
  exit 1
fi
