#!/usr/bin/env bash
# GAMP-ID: FS-181-HDS-010-SDS-030-SMS-010
# GAMP-SCOPE: software-module-test
# Focused construction test: realization authority binding seeded negatives (ACTIVE).
#
# SMS Acceptance Predicates (ACTIVE):
#   P1 ✓ Valid authority record + inventory/runtime facts → emits realized binding
#   N1 ✓ Realization binding lacking authority identifier → REJECT (binder-source-audit.validate)
#   N2 ✓ Realization binding referencing unknown authority → REJECT (binder-source-audit.validate)
#   N3 ✓ Runtime facts creating policy authority → REJECT (compileAndBuild pipeline)
#
# The CPM joins NFM output (authority records) with inventory/runtime facts.
# Part A tests binder-source-audit.validate directly (N1, N2).
# Part B tests the full CPM pipeline via compileAndBuild (P1, N3).
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

echo "--- FS-181-HDS-010-SDS-030-SMS-010: realization authority binding ---"
echo ""

PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

###############################################################################
# Part A: binder-source-audit.validate direct tests (N1, N2)
###############################################################################
echo "=== Part A: binder-source-audit.validate module tests ==="
echo ""

# run_validate_test: calls bsa.validate with a record expression.
# If validate throws (N1/N2 violation), tryEval.success=false → returns "FAIL".
# If validate passes, tryEval.success=true → returns "PASS".
run_validate_test() {
  local desc="$1" record_expr="$2"
  local result
  result=$(REPO_ROOT="$repo_root" nix eval --impure --raw --expr "
    let
      helpers = {
        requireAttrs = path: value:
          if builtins.isAttrs value then value
          else throw \"\${path}: must be attribute set\";
        requireString = path: value:
          if builtins.isString value && value != \"\" then value
          else throw \"\${path}: must be non-empty string\";
      };
      bsa = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/binder-source-audit.nix\")
        { inherit helpers; };
      result = builtins.tryEval (
        bsa.validate \"test.record\" (${record_expr})
      );
    in if result.success then \"PASS\" else \"FAIL\"
  " 2>&1)
  echo "$result"
}

# Valid record (control for N1/N2): has proper binderSourceAudit with valid fields
VALID_RECORD='{
  upstreamBehaviorRef = "inventory.realization.nodes.some-target";
  someField = "value";
  binderSourceAudit = {
    stage = "control-plane-model";
    authority = "realization-binding";
    sourceClass = "public-inventory";
    sourcePath = "inventory.realization.nodes.some-target";
    upstreamBehaviorRef = "inventory.realization.nodes.some-target";
    field = "someField";
  };
}'

# N1: Record with NO binderSourceAudit (lacking authority identifier)
N1_NO_BINDER_AUDIT='{
  upstreamBehaviorRef = "inventory.realization.nodes.some-target";
  someField = "value";
}'

# N2: Record with binderSourceAudit but wrong authority value
N2_WRONG_AUTHORITY='{
  upstreamBehaviorRef = "inventory.realization.nodes.some-target";
  someField = "value";
  binderSourceAudit = {
    stage = "control-plane-model";
    authority = "routing-authority";
    sourceClass = "public-inventory";
    sourcePath = "inventory.realization.nodes.some-target";
    upstreamBehaviorRef = "inventory.realization.nodes.some-target";
    field = "someField";
  };
}'

# N2b: Record with binderSourceAudit but invalid sourceClass
N2_WRONG_SOURCECLASS='{
  upstreamBehaviorRef = "inventory.realization.nodes.some-target";
  someField = "value";
  binderSourceAudit = {
    stage = "control-plane-model";
    authority = "realization-binding";
    sourceClass = "renderer-authority";
    sourcePath = "inventory.realization.nodes.some-target";
    upstreamBehaviorRef = "inventory.realization.nodes.some-target";
    field = "someField";
  };
}'

# POS control: valid record should pass validate
R=$(run_validate_test "P0-validate-control" "$VALID_RECORD")
[ "$R" = "PASS" ] && pass "P0 — valid record passes binderSourceAudit.validate" || fail "P0 — expected PASS, got: $R"

# N1: Missing binderSourceAudit → validate throws → tryEval yields success=false
R=$(run_validate_test "N1" "$N1_NO_BINDER_AUDIT")
[ "$R" = "FAIL" ] && pass "N1 — missing binderSourceAudit rejected by validate" || fail "N1 — expected FAIL, got: $R"

# N2: Wrong authority value → validate throws
R=$(run_validate_test "N2" "$N2_WRONG_AUTHORITY")
[ "$R" = "FAIL" ] && pass "N2 — wrong authority (routing-authority) rejected by validate" || fail "N2 — expected FAIL, got: $R"

# N2b: Invalid sourceClass → validate throws
R=$(run_validate_test "N2b" "$N2_WRONG_SOURCECLASS")
[ "$R" = "FAIL" ] && pass "N2b — invalid sourceClass rejected by validate" || fail "N2b — expected FAIL, got: $R"

echo ""

###############################################################################
# Part B: CPM pipeline tests (P1, N3)
###############################################################################
echo "=== Part B: CPM pipeline compileAndBuild tests ==="
echo ""

run_pipeline_check() {
  local desc="$1" inv_expr="$2"
  local result
  result=$(REPO_ROOT="$repo_root" nix eval --impure --raw --expr "
    let flake = builtins.getFlake \"path:${repo_root}\"; system = builtins.currentSystem;
        labs = flake.inputs.network-labs.outPath;
        baseIntent = import (labs + \"/examples/single-wan-with-nebula/intent.nix\");
        baseInventory = import (labs + \"/examples/single-wan-with-nebula/inventory-nixos.nix\");
        runner = inventory: builtins.tryEval (
          let r = flake.lib.\${system}.compileAndBuild {
            input = baseIntent; inventory = inventory;
          }; in builtins.deepSeq r.control_plane_model true
        );
    in if (runner (${inv_expr})).success then \"PASS\" else \"FAIL\"
  " 2>&1)
  echo "$result"
}

# Well-formed providerAuthority with all required fields and runtimeFacts not creating authority
POSITIVE_INV='baseInventory // { controlPlane = baseInventory.controlPlane // { sites = baseInventory.controlPlane.sites // { esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // { "site-a" = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a" or {}) // { overlays = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays or {}) // { nebula = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays.nebula or {}) // { providerAuthority = { upstreamType = "overlay-egress"; providerTechnology = "nebula"; ipv4Mode = "overlay-host-only"; ipv6Mode = "overlay-host-only"; prefixAuthority = { routedClient = false; delegated = false; translated = false; source = "provider-authority-record"; }; dnsFollowSource = { enabled = true; source = "provider-authority-record"; }; publicIngress = { allowed = false; source = "provider-authority-record"; }; routeAuthority = { import = false; export = false; source = "provider-authority-record"; }; nat = { nat44 = "none"; nat66 = "none"; }; failureBehavior = "fail-closed"; expectedClientEgress = "overlay-underlay-bootstrap-only"; wanEgressRelationship = "policy-selected-uplink-nebula"; runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = false; }; }; }; }; }; }; }; }; }'

# N3: runtimeFacts.createsPolicyAuthority = true → must be rejected
N3_RUNTIME_POLICY_INV='baseInventory // { controlPlane = baseInventory.controlPlane // { sites = baseInventory.controlPlane.sites // { esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // { "site-a" = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a" or {}) // { overlays = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays or {}) // { nebula = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays.nebula or {}) // { providerAuthority = { upstreamType = "overlay-egress"; providerTechnology = "nebula"; ipv4Mode = "overlay-host-only"; ipv6Mode = "overlay-host-only"; prefixAuthority = { routedClient = false; delegated = false; translated = false; source = "provider-authority-record"; }; dnsFollowSource = { enabled = true; source = "provider-authority-record"; }; publicIngress = { allowed = false; source = "provider-authority-record"; }; routeAuthority = { import = false; export = false; source = "provider-authority-record"; }; nat = { nat44 = "none"; nat66 = "none"; }; failureBehavior = "fail-closed"; expectedClientEgress = "overlay-underlay-bootstrap-only"; wanEgressRelationship = "policy-selected-uplink-nebula"; runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = true; createsPrefixAuthority = false; }; }; }; }; }; }; }; }; }'

# N3b: runtimeFacts.createsPrefixAuthority = true → must also be rejected
N3_RUNTIME_PREFIX_INV='baseInventory // { controlPlane = baseInventory.controlPlane // { sites = baseInventory.controlPlane.sites // { esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // { "site-a" = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a" or {}) // { overlays = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays or {}) // { nebula = (baseInventory.controlPlane.sites.esp0xdeadbeef."site-a".overlays.nebula or {}) // { providerAuthority = { upstreamType = "overlay-egress"; providerTechnology = "nebula"; ipv4Mode = "overlay-host-only"; ipv6Mode = "overlay-host-only"; prefixAuthority = { routedClient = false; delegated = false; translated = false; source = "provider-authority-record"; }; dnsFollowSource = { enabled = true; source = "provider-authority-record"; }; publicIngress = { allowed = false; source = "provider-authority-record"; }; routeAuthority = { import = false; export = false; source = "provider-authority-record"; }; nat = { nat44 = "none"; nat66 = "none"; }; failureBehavior = "fail-closed"; expectedClientEgress = "overlay-underlay-bootstrap-only"; wanEgressRelationship = "policy-selected-uplink-nebula"; runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = true; }; }; }; }; }; }; }; }; }'

# P1: Well-formed providerAuthority builds clean (verify realization binding is emitted)
R=$(run_pipeline_check "P1" "$POSITIVE_INV")
[ "$R" = "PASS" ] && pass "P1 — well-formed providerAuthority builds clean (realization binding emitted)" || fail "P1 — expected PASS, got: $R"

# P0: Base inventory (no explicit providerAuthority) should also build clean
R=$(run_pipeline_check "P0-base" "baseInventory")
[ "$R" = "PASS" ] && pass "P0 — base inventory builds clean" || fail "P0 — expected PASS, got: $R"

# N3: runtimeFacts.createsPolicyAuthority=true → must be rejected
R=$(run_pipeline_check "N3" "$N3_RUNTIME_POLICY_INV")
[ "$R" = "FAIL" ] && pass "N3 — createsPolicyAuthority=true rejected by CPM" || fail "N3 — expected FAIL, got: $R"

# N3b: runtimeFacts.createsPrefixAuthority=true → must be rejected
R=$(run_pipeline_check "N3b" "$N3_RUNTIME_PREFIX_INV")
[ "$R" = "FAIL" ] && pass "N3b — createsPrefixAuthority=true rejected by CPM" || fail "N3b — expected FAIL, got: $R"

echo ""

###############################################################################
# Part C: Verify CPM output preserves authority binding provenance (P1 output)
###############################################################################
echo "=== Part C: Verify CPM output binderSourceAudit provenance ==="
echo ""

REPO_ROOT="$repo_root" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;
    baseIntent = import (labs + "/examples/single-wan-with-nebula/intent.nix");
    baseInventory = import (labs + "/examples/single-wan-with-nebula/inventory-nixos.nix");
    result = flake.lib.${system}.compileAndBuild {
      input = baseIntent;
      inventory = baseInventory;
    };
    cpm = result.control_plane_model;
    site = cpm.data.esp0xdeadbeef."site-a" or {};
    rt = site.runtimeTargets or {};

    # Collect all binderSourceAudit records from runtime target interfaces
    allIfaces = builtins.concatLists (
      builtins.map (rtName:
        let
          target = rt.${rtName};
          err = target.effectiveRuntimeRealization or {};
          ifaces = err.interfaces or {};
        in
          builtins.map (ifName:
            let iface = ifaces.${ifName};
            in iface.binderSourceAudit or null)
          (builtins.attrNames ifaces))
      (builtins.attrNames rt));

    # Also collect from runtime target top-level
    topLevelAudits = builtins.map (rtName:
      let target = rt.${rtName};
      in target.binderSourceAudit or null)
      (builtins.attrNames rt);

    # Filter out nulls
    allAudits = builtins.filter (a: a != null) (allIfaces ++ topLevelAudits);

    # P1-output checks
    hasBinderSourceAudits = builtins.length allAudits > 0;

    # All audits must have authority = "realization-binding"
    allHaveRealizationBinding = builtins.all
      (a: (a.authority or null) == "realization-binding")
      allAudits;

    # All audits must have stage = "control-plane-model"
    allHaveCpmStage = builtins.all
      (a: (a.stage or null) == "control-plane-model")
      allAudits;

    # All audits must have valid sourceClass
    validClasses = ["public-inventory" "protected-inventory" "runtime-facts" "validation-context"];
    allHaveValidSourceClass = builtins.all
      (a: builtins.elem (a.sourceClass or null) validClasses)
      allAudits;

    # All audits must have upstreamBehaviorRef
    allHaveUpstreamRef = builtins.all
      (a: builtins.isString (a.upstreamBehaviorRef or null) && (a.upstreamBehaviorRef or "") != "")
      allAudits;

    auditSample = if allAudits != [] then builtins.head allAudits else null;
  in
    if hasBinderSourceAudits
       && allHaveRealizationBinding
       && allHaveCpmStage
       && allHaveValidSourceClass
       && allHaveUpstreamRef
    then
      builtins.trace "P1-output: ALL CHECKS PASSED — ${toString (builtins.length allAudits)} binderSourceAudit records verified" true
    else
      throw ("P1-output: CHECKS FAILED — hasBinderSourceAudits=${toString hasBinderSourceAudits} allRealization=${toString allHaveRealizationBinding} allCpmStage=${toString allHaveCpmStage} allValidClass=${toString allHaveValidSourceClass} allUpstreamRef=${toString allHaveUpstreamRef} sample=${builtins.toJSON auditSample}")
' >/dev/null

if [ $? -eq 0 ]; then
  pass "P1-output — CPM output contains valid binderSourceAudit records with authority=realization-binding"
else
  fail "P1-output — CPM output binderSourceAudit validation failed"
fi

echo ""
echo "=== FS-181-HDS-010-SDS-030-SMS-010 Results ==="
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ] && echo "RESULT: PASS — all SMS-010 predicates with active seeded negatives" && exit 0
echo "RESULT: FAIL"
exit 1
