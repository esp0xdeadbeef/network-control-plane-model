#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-035
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM filters self-referential DNS forwarders.
#
# SMS-035 MR2 (line 29-30): Renderer shall produce unbound config with
# a valid upstream forwarder address that is NOT self-referential.
# SMS-035 N1 (line 75-77): Seeded negative — forward-addr equal to an
# interface address → reject with diagnostic.
#
# This CMC test proves the CPM layer filters self-referential forwarders
# before emission, so the renderer never sees them.
#
# Predicates:
# 1. Self-referential forwarder filtered out (negative case)
# 2. Disjoint forwarders retained (positive case)
# 3. Diagnostic emitted with FS-540-HDS-010-SDS-010-SMS-035 tag
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

all_checks_passed=true

echo "--- FS-540-HDS-010-SDS-010-SMS-035: CPM self-referential DNS forwarder filter ---"
echo ""

# ============================================================
# Shared Nix expression prefix (bindings only, no 'in')
# ============================================================
nix_expr_bindings() {
  echo "repoRoot = builtins.getEnv \"REPO_ROOT\";"
  echo "lib = import <nixpkgs/lib>;"
  echo "helpers = import (repoRoot + \"/lib/contract.nix\") { inherit lib; };"
  echo "common = {"
  echo "  attrsOrEmpty = v: if builtins.isAttrs v then v else {};"
  echo "  listOrEmpty = v: if builtins.isList v then v else [];"
  echo "  failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";"
  echo "};"
  echo "policyDerivedDnsForwardersForListeners = listeners: [];"
  echo "policyDerivedDnsAllowedClassesForListeners = listeners: [\"local-access\"];"
  echo "policyDerivedDnsUpstreamRecordsForListeners = listeners: [];"
  echo "dnsContractsMod = import (repoRoot + \"/src/cpm/ControlModule/runtime-targets/dns-contracts.nix\") {"
  echo "  inherit lib helpers common"
  echo "    policyDerivedDnsAllowedClassesForListeners"
  echo "    policyDerivedDnsForwardersForListeners"
  echo "    policyDerivedDnsUpstreamRecordsForListeners;"
  echo "};"
}

# ============================================================
# Test helper: evaluate a Nix expression and check result
# ============================================================
nix_eval_test() {
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
# Predicate 1: Self-referential forwarder is filtered out
# ============================================================
echo "--- Predicate 1: Self-referential forwarder filter (negative) ---"

self_ref_expr="let
  $(
    nix_expr_bindings
  )
  selfRefTarget = {
    role = \"access\";
    placement = { target = \"test-node\"; };
    services.dns = {
      listen = [\"10.0.0.1\" \"127.0.0.1\" \"::1\"];
      forwarders = [\"10.0.0.1\" \"8.8.8.8\"];
      allowedUpstreamClasses = [\"local-access\"];
    };
    advertisements.dhcp4 = [{
      dnsServers = [\"10.0.0.1\"];
      subnet = \"10.0.0.0/24\";
    }];
  };
  result = dnsContractsMod selfRefTarget;
  forwarders = result.services.dns.forwarders or [];
in {
  selfRefFiltered = !(builtins.elem \"10.0.0.1\" forwarders);
  selfRefRetained = builtins.elem \"8.8.8.8\" forwarders;
  forwarderCount = builtins.length forwarders;
  inherit forwarders;
}"

nix_eval_test \
  "Self-referential 10.0.0.1 is filtered out of forwarders" \
  "${self_ref_expr}.selfRefFiltered" \
  "true"

nix_eval_test \
  "Non-self-referential 8.8.8.8 is retained in forwarders" \
  "${self_ref_expr}.selfRefRetained" \
  "true"

nix_eval_test \
  "Only one forwarder remains after filtering" \
  "${self_ref_expr}.forwarderCount" \
  "1"

# ============================================================
# Predicate 2: Disjoint forwarders are all retained
# ============================================================
echo "--- Predicate 2: Disjoint forwarders retained (positive) ---"

disjoint_expr="let
  $(
    nix_expr_bindings
  )
  disjointTarget = {
    role = \"access\";
    placement = { target = \"test-node\"; };
    services.dns = {
      listen = [\"10.0.0.1\" \"127.0.0.1\"];
      forwarders = [\"8.8.8.8\" \"1.1.1.1\"];
      allowedUpstreamClasses = [\"local-access\"];
    };
    advertisements.dhcp4 = [{
      dnsServers = [\"10.0.0.1\"];
      subnet = \"10.0.0.0/24\";
    }];
  };
  result = dnsContractsMod disjointTarget;
  forwarders = result.services.dns.forwarders or [];
in {
  forwarderCount = builtins.length forwarders;
  inherit forwarders;
}"

nix_eval_test \
  "Both disjoint forwarders retained (count = 2)" \
  "${disjoint_expr}.forwarderCount" \
  "2"

# ============================================================
# Predicate 3: Diagnostic trace emitted for self-referential case
# ============================================================
echo "--- Predicate 3: Diagnostic trace emitted ---"

# Run the self-ref case again, capturing stderr
diag_output="$(REPO_ROOT="${repo_root}" nix eval --impure --expr "${self_ref_expr}.forwarders" 2>&1 1>/dev/null || true)"
if echo "${diag_output}" | grep -q "FS-540-HDS-010-SDS-010-SMS-035"; then
  echo "PASS: Diagnostic trace contains FS-540-HDS-010-SDS-010-SMS-035 tag"
else
  echo "FAIL: Diagnostic trace missing FS-540-HDS-010-SDS-010-SMS-035 tag"
  echo "  stderr: ${diag_output}"
  all_checks_passed=false
fi

if echo "${diag_output}" | grep -q "self-referential"; then
  echo "PASS: Diagnostic trace contains 'self-referential' message"
else
  echo "FAIL: Diagnostic trace missing 'self-referential' in message"
  echo "  stderr: ${diag_output}"
  all_checks_passed=false
fi

# ============================================================
# Predicate 4: No diagnostic for disjoint case
# ============================================================
echo "--- Predicate 4: No diagnostic for disjoint forwarders ---"

disjoint_diag="$(REPO_ROOT="${repo_root}" nix eval --impure --expr "${disjoint_expr}.forwarders" 2>&1 1>/dev/null || true)"
if echo "${disjoint_diag}" | grep -q "FS-540-HDS-010-SDS-010-SMS-035"; then
  echo "FAIL: Unexpected diagnostic for disjoint forwarders"
  echo "  stderr: ${disjoint_diag}"
  all_checks_passed=false
else
  echo "PASS: No diagnostic emitted for disjoint forwarders"
fi

# ============================================================
# Report
# ============================================================
echo ""
if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS: All FS-540-HDS-010-SDS-010-SMS-035 self-referential forwarder filter checks passed."
  exit 0
else
  echo "FAIL: One or more checks failed."
  exit 1
fi
