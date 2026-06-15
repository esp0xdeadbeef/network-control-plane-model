#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-110
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM DHCP server/client authority declaration.
#
# SMS-110: CPM shall emit dhcpServer.enabled and dhcpClient.enabled per interface
# so renderers do not hardcode DHCPServer=true.
#
# Predicates:
# 1. All interfaces get dhcpAuthority.server.enabled = false by default
# 2. All interfaces get dhcpAuthority.client.enabled = false by default
# 3. WAN interfaces have dhcpAuthority fields present
# 4. Tenant interfaces have dhcpAuthority fields present
# 5. Seeded negative: no interface defaults to server.enabled = true
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

all_checks_passed=true

echo "--- FS-380-HDS-020-SDS-010-SMS-110: CPM DHCP authority declaration ---"
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

# ============================================================
# Helper: taxonomyFor for a given sourceKind
# ============================================================
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
# Predicate 1: WAN DHCP authority defaults
# ============================================================
echo "--- Predicate 1: WAN interface DHCP authority defaults ---"

nix_eval_test \
  "WAN dhcpServer.enabled = false (no model intent)" \
  "$(taxonomy_expr wan core) result.dhcpAuthority.server.enabled" \
  "false"

nix_eval_test \
  "WAN dhcpClient.enabled = false by default" \
  "$(taxonomy_expr wan core) result.dhcpAuthority.client.enabled" \
  "false"

nix_eval_test \
  "WAN dhcpAuthority.server.pool is null" \
  "$(taxonomy_expr wan core) result.dhcpAuthority.server.pool" \
  "null"

# ============================================================
# Predicate 2: Tenant DHCP authority defaults
# ============================================================
echo "--- Predicate 2: Tenant interface DHCP authority defaults ---"

nix_eval_test \
  "Tenant dhcpServer.enabled = false" \
  "$(taxonomy_expr tenant access) result.dhcpAuthority.server.enabled" \
  "false"

nix_eval_test \
  "Tenant dhcpClient.enabled = false" \
  "$(taxonomy_expr tenant access) result.dhcpAuthority.client.enabled" \
  "false"

# ============================================================
# Predicate 3: Seeded negative — no interface defaults to server=true
# ============================================================
echo "--- Predicate 3: Seeded negative — no hardcoded DHCP defaults ---"

for kind in wan p2p tenant overlay; do
  nix_eval_test \
    "${kind}: dhcpServer.enabled is never true by default" \
    "$(taxonomy_expr "${kind}" core) result.dhcpAuthority.server.enabled" \
    "false"
done

# ============================================================
# Report
# ============================================================
echo ""
if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS: All FS-380-HDS-020-SDS-010-SMS-110 DHCP authority checks passed."
  exit 0
else
  echo "FAIL: One or more checks failed."
  exit 1
fi
