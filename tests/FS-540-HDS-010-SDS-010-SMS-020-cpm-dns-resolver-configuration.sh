#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM DNS resolver configuration authority.
#
# SMS-020: CPM shall emit dnsResolver per interface with resolver4, resolver6,
# and resolverSource fields so renderers do not infer resolver addresses.
#
# Predicates:
# 1. Access-client tenant interfaces get resolverSource = "local-recursive"
# 2. Access-client tenant interfaces get resolver4 = "127.0.0.1"
# 3. Access-client tenant interfaces get resolver6 = "::1"
# 4. Non-access tenant interfaces get resolverSource = "upstream-forwarder"
# 5. WAN interfaces get resolverSource = "dhcp-provided"
# 6. P2P interfaces get resolverSource = "none"
# 7. Seeded negative: P2P does not get a resolver address
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

all_checks_passed=true

echo "--- FS-540-HDS-010-SDS-010-SMS-020: CPM DNS resolver configuration authority ---"
echo ""

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

taxonomy_expr() {
  local kind="$1" role="${2:-core}"
  echo "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/lib/contract.nix\") { lib = import <nixpkgs/lib>; };
      common = {
        attrsOrEmpty = v: if builtins.isAttrs v then v else {};
        failInventory = path: msg: builtins.throw \"\${path}: \${msg}\";
      };
      taxonomy = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix\") { inherit helpers common; };
      result = taxonomy.taxonomyFor {
        ifacePath = \"test.${kind}\";
        ifName = \"if0\";
        sourceKind = \"${kind}\";
        backingRef = { name = \"test\"; };
        nodeRole = \"${role}\";
        targetDef = null;
        portBinding = null;
        fabricLinkBinding = null;
        overlayProvisioning = {};
      };
    in"
}

# ============================================================
# Predicate 1: Access-client tenant → local-recursive
# ============================================================
echo "--- Predicate 1: Access-client DNS resolver ---"

nix_eval_test \
  "Access-client tenant: resolverSource = local-recursive" \
  "$(taxonomy_expr tenant access) result.dnsResolver.resolverSource" \
  "\"local-recursive\""

nix_eval_test \
  "Access-client tenant: resolver4 = 127.0.0.1" \
  "$(taxonomy_expr tenant access) result.dnsResolver.resolver4" \
  "\"127.0.0.1\""

nix_eval_test \
  "Access-client tenant: resolver6 = ::1" \
  "$(taxonomy_expr tenant access) result.dnsResolver.resolver6" \
  "\"::1\""

# ============================================================
# Predicate 2: Non-access tenant → upstream-forwarder
# ============================================================
echo "--- Predicate 2: Non-access tenant DNS resolver ---"

nix_eval_test \
  "Core tenant: resolverSource = upstream-forwarder" \
  "$(taxonomy_expr tenant core) result.dnsResolver.resolverSource" \
  "\"upstream-forwarder\""

nix_eval_test \
  "Core tenant: resolver4 is null" \
  "$(taxonomy_expr tenant core) result.dnsResolver.resolver4" \
  "null"

# ============================================================
# Predicate 3: WAN → dhcp-provided
# ============================================================
echo "--- Predicate 3: WAN DNS resolver ---"

nix_eval_test \
  "WAN: resolverSource = dhcp-provided" \
  "$(taxonomy_expr wan core) result.dnsResolver.resolverSource" \
  "\"dhcp-provided\""

nix_eval_test \
  "WAN: resolver4 is null (provided at runtime)" \
  "$(taxonomy_expr wan core) result.dnsResolver.resolver4" \
  "null"

# ============================================================
# Predicate 4: P2P → none
# ============================================================
echo "--- Predicate 4: P2P DNS resolver ---"

nix_eval_test \
  "P2P: resolverSource = none" \
  "$(taxonomy_expr p2p core) result.dnsResolver.resolverSource" \
  "\"none\""

nix_eval_test \
  "P2P: resolver4 is null" \
  "$(taxonomy_expr p2p core) result.dnsResolver.resolver4" \
  "null"

# ============================================================
# Predicate 5: Seeded negative — P2P does not get a resolver
# ============================================================
echo "--- Predicate 5: Seeded negative — no DNS on non-participating interfaces ---"

nix_eval_test \
  "P2P: does NOT get local-recursive resolver" \
  "$(taxonomy_expr p2p core) result.dnsResolver.resolverSource != \"local-recursive\"" \
  "true"

# ============================================================
# Report
# ============================================================
echo ""
if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS: All FS-540-HDS-010-SDS-010-SMS-020 DNS resolver configuration checks passed."
  exit 0
else
  echo "FAIL: One or more checks failed."
  exit 1
fi
