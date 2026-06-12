#!/usr/bin/env bash
# GAMP-ID: FS-260-HDS-010-SDS-010-SMS-012
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM emulation subnet injection into fabricSubnets.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

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

# P1: emulation subnet included
nix_eval "10.11.0.0/24 in fabricSubnets" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" \"198.51.100.0/24\" ];" \
  'o: builtins.elem "10.11.0.0/24" o.fabricSubnets' \
  "true"

nix_eval "198.51.100.0/24 in fabricSubnets" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" \"198.51.100.0/24\" ];" \
  'o: builtins.elem "198.51.100.0/24" o.fabricSubnets' \
  "true"

# P2: default (no emulation) — 2 entries (1 tenant + 1 transit)
nix_eval "default fabricSubnets length = 2" \
  "${BASE_ARGS}" \
  'o: builtins.length o.fabricSubnets' \
  "2"

# P3: fabricSubnetSources counts
nix_eval "emulationCount = 2" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" \"198.51.100.0/24\" ];" \
  'o: o.fabricSubnetSources.emulationCount' \
  "2"

nix_eval "tenantCount correct" \
  "${BASE_ARGS} emulationSubnets = [ \"10.11.0.0/24\" ];" \
  'o: o.fabricSubnetSources.tenantCount' \
  "1"

# P4: seeded negative — empty emulation → count 0
nix_eval "empty emulationSubnets → count 0" \
  "${BASE_ARGS} emulationSubnets = [];" \
  'o: o.fabricSubnetSources.emulationCount' \
  "0"

# P5: deduplication — emulation subnet same as tenant subnet
nix_eval "dedup: duplicate subnet counted once" \
  "${BASE_ARGS} emulationSubnets = [ \"10.20.0.0/24\" ];" \
  'o: builtins.length o.fabricSubnets' \
  "2"

echo ""
if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS: FS-260-HDS-010-SDS-010-SMS-012 (8/8 assertions)"
  exit 0
else
  echo "FAIL: One or more checks failed."
  exit 1
fi
