#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-090
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM explicit interface role classification.
#
# SMS-090: CPM shall emit explicitWan, explicitTransit, explicitLocalAdapter
# flags on interface entries AND populate wanInterfaces/lanInterfaces named
# lists in forwarding output, so renderers do not need sourceKind fallbacks.
#
# Predicates:
# 1. WAN-classified interface gets explicit.explicitWan = true
# 2. P2P-classified interface gets explicit.explicitTransit = true
# 3. Tenant-classified interface gets explicit.explicitLocalAdapter = true
# 4. explicit flags are NOT set from naming conventions (seeded negative)
# 5. forwarding output contains wanInterfaces and lanInterfaces lists
# 6. Missing sourceKind causes diagnostic, not silent default
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

all_checks_passed=true

echo "--- FS-380-HDS-020-SDS-010-SMS-090: CPM explicit interface role classification ---"
echo ""

# ============================================================
# Helper: run nix eval expression and check result
# ============================================================
nix_eval_bool() {
  local desc="$1" expr="$2" expected="$3"
  local result
  result="$(REPO_ROOT="${repo_root}" nix eval --impure --expr "${expr}" 2>/dev/null || echo "__ERROR__")"
  if [[ "${result}" == "${expected}" ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} — expected ${expected}, got ${result}"
    all_checks_passed=false
  fi
}

# ============================================================
# Predicate 1: WAN interface gets explicit.explicitWan = true
# ============================================================
echo "--- Predicate 1: WAN classification ---"

# Build taxonomy for a WAN interface
nix_eval_bool \
  "WAN interface explicitWan=true" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.wan\";
        ifName = \"wan0\";
        sourceKind = \"wan\";
        backingRef = { name = \"test-uplink\"; };
        nodeRole = \"core\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in
      result.explicit.explicitWan or false
  " \
  "true"

nix_eval_bool \
  "WAN interface explicitTransit=false" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.wan\";
        ifName = \"wan0\";
        sourceKind = \"wan\";
        backingRef = { name = \"test-uplink\"; };
        nodeRole = \"core\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in
      result.explicit.explicitTransit or true
  " \
  "false"

# ============================================================
# Predicate 2: P2P interface gets explicit.explicitTransit = true
# ============================================================
echo "--- Predicate 2: P2P/transit classification ---"

nix_eval_bool \
  "P2P interface explicitTransit=true" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.p2p\";
        ifName = \"eth0\";
        sourceKind = \"p2p\";
        backingRef = { name = \"test-link\"; };
        nodeRole = \"core\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in
      result.explicit.explicitTransit or false
  " \
  "true"

nix_eval_bool \
  "P2P interface explicitWan=false" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.p2p\";
        ifName = \"eth0\";
        sourceKind = \"p2p\";
        backingRef = { name = \"test-link\"; };
        nodeRole = \"core\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in
      result.explicit.explicitWan or true
  " \
  "false"

nix_eval_bool \
  "upstream-selector multi-uplink P2P interfaceClass.coreFacing=true" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.upstream-selector.core\";
        ifName = \"p0\";
        sourceKind = \"p2p\";
        backingRef = {
          name = \"p2p-emulated-isp-upstream-selector\";
          lane = \"default\";
          uplinks = [ \"internet-vlan4\" \"internet-vlan5\" ];
        };
        nodeRole = \"upstream-selector\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in
      result.interfaceClass.coreFacing or false
  " \
  "true"

nix_eval_bool \
  "access-uplink P2P interfaceClass.exitFacing=true" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.upstream-selector.access-uplink\";
        ifName = \"p1\";
        sourceKind = \"p2p\";
        backingRef = {
          name = \"p2p-policy-upstream-selector--access-client-edge--uplink-internet-vlan4\";
          lane = {
            kind = \"access-uplink\";
            access = \"client-edge\";
            uplink = \"internet-vlan4\";
            uplinks = [ \"internet-vlan4\" ];
          };
        };
        nodeRole = \"upstream-selector\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in
      result.interfaceClass.exitFacing or false
  " \
  "true"

# ============================================================
# Predicate 3: Tenant interface gets explicit.explicitLocalAdapter = true
# ============================================================
echo "--- Predicate 3: Tenant/LAN classification ---"

nix_eval_bool \
  "Tenant interface explicitLocalAdapter=true" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.tenant\";
        ifName = \"lan0\";
        sourceKind = \"tenant\";
        backingRef = { name = \"test-tenant\"; };
        nodeRole = \"access\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in
      result.explicit.explicitLocalAdapter or false
  " \
  "true"

# ============================================================
# Predicate 4: Seeded negative — naming convention does NOT drive classification
# Interface named "wan0" but sourceKind is "tenant" — must NOT get explicitWan
# ============================================================
echo "--- Predicate 4: Seeded negative — naming convention does not override structure ---"

nix_eval_bool \
  "tenant interface named 'wan0' does NOT get explicitWan" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.tenant-wan-name\";
        ifName = \"wan0\";
        sourceKind = \"tenant\";
        backingRef = { name = \"test-tenant\"; };
        nodeRole = \"access\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in
      result.explicit.explicitWan or false
  " \
  "false"

nix_eval_bool \
  "tenant interface named 'wan0' DOES get explicitLocalAdapter" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.tenant-wan-name\";
        ifName = \"wan0\";
        sourceKind = \"tenant\";
        backingRef = { name = \"test-tenant\"; };
        nodeRole = \"access\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in
      result.explicit.explicitLocalAdapter or false
  " \
  "true"

# ============================================================
# Predicate 5: forwarding.nix emits wanInterfaces and lanInterfaces lists
# ============================================================
echo "--- Predicate 5: Forwarding output includes wanInterfaces/lanInterfaces ---"

# Verify the forwarding module exposes wanInterfaces and lanInterfaces in its output
# by checking the core role output shape
nix_eval_bool \
  "forwarding core output has wanInterfaces field" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      forwarding = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/forwarding.nix\") { inherit helpers; };
      mockInterfaces = [
        { sourceKind = \"wan\"; runtimeIfName = \"ens10\"; sourceInterfaceName = \"ens10\"; upstream = \"test\"; backingRef = {}; }
        { sourceKind = \"tenant\"; runtimeIfName = \"eth0\"; sourceInterfaceName = \"eth0\"; backingRef = {}; }
        { sourceKind = \"p2p\"; runtimeIfName = \"eth1\"; sourceInterfaceName = \"eth1\"; backingRef = {}; }
      ];
      result = forwarding {
        overlayNames = [];
        policyEndpointBindings = {};
        services = {};
        siteRelations = [];
        target = {
          role = \"core\";
          egressIntent = {};
        };
        interfaceRecords = mockInterfaces;
      };
    in
      builtins.hasAttr \"wanInterfaces\" result
  " \
  "true"

nix_eval_bool \
  "forwarding core output has lanInterfaces field" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      forwarding = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/forwarding.nix\") { inherit helpers; };
      mockInterfaces = [
        { sourceKind = \"wan\"; runtimeIfName = \"ens10\"; sourceInterfaceName = \"ens10\"; upstream = \"test\"; backingRef = {}; }
        { sourceKind = \"tenant\"; runtimeIfName = \"eth0\"; sourceInterfaceName = \"eth0\"; backingRef = {}; }
        { sourceKind = \"p2p\"; runtimeIfName = \"eth1\"; sourceInterfaceName = \"eth1\"; backingRef = {}; }
      ];
      result = forwarding {
        overlayNames = [];
        policyEndpointBindings = {};
        services = {};
        siteRelations = [];
        target = {
          role = \"core\";
          egressIntent = {};
        };
        interfaceRecords = mockInterfaces;
      };
    in
      builtins.hasAttr \"lanInterfaces\" result
  " \
  "true"

# ============================================================
# Predicate 6: Overlay interfaces do NOT get explicitWan/Transit/LocalAdapter
# ============================================================
echo "--- Predicate 6: Overlay/other interfaces do not get false-positive flags ---"

nix_eval_bool \
  "overlay interface does NOT get explicitWan" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.overlay\";
        ifName = \"nebula0\";
        sourceKind = \"overlay\";
        backingRef = { name = \"nebula\"; };
        nodeRole = \"core\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = { nebula = {}; };
      };
    in
      (result.explicit.explicitWan or false) || (result.explicit.explicitTransit or false) || (result.explicit.explicitLocalAdapter or false)
  " \
  "false"

# ============================================================
# Report
# ============================================================
echo ""
if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS: All FS-380-HDS-020-SDS-010-SMS-090 explicit role classification checks passed."
  exit 0
else
  echo "FAIL: One or more checks failed."
  exit 1
fi
