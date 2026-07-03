#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-100
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM NAT fabric prefix inclusion.
#
# SMS-100: CPM shall include p2p fabric subnets in masqueradeSourcePrefixes
# so renderers don't need to derive them from interface addresses.
#
# Predicates:
# 1. P2P interface prefix included in masqueradeFabricPrefixes4
# 2. Tenant interface prefix included in masqueradeFabricPrefixes4
# 3. /32 host routes excluded from fabric prefixes
# 4. WAN interface prefix EXCLUDED from fabric prefixes (seeded negative)
# 5. Overlay interface prefix EXCLUDED from fabric prefixes
# 6. masqueradeSourcePrefixes4 includes both tenant and fabric prefixes
# 7. Routed internal fabric prefixes behind the egress core are included
# 8. No fabric prefixes emitted when NAT is not enabled
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

all_checks_passed=true

echo "--- FS-380-HDS-020-SDS-010-SMS-100: CPM NAT fabric prefix inclusion ---"
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

nix_eval_list_contains() {
  local desc="$1" expr="$2" element="$3"
  local result
  result="$(REPO_ROOT="${repo_root}" nix eval --impure --json --expr "${expr}" 2>/dev/null || echo "__ERROR__")"
  if echo "${result}" | grep -qF "\"${element}\""; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} — expected list to contain \"${element}\", got ${result}"
    all_checks_passed=false
  fi
}

nix_eval_list_not_contains() {
  local desc="$1" expr="$2" element="$3"
  local result
  result="$(REPO_ROOT="${repo_root}" nix eval --impure --json --expr "${expr}" 2>/dev/null || echo "__ERROR__")"
  if echo "${result}" | grep -qF "\"${element}\""; then
    echo "FAIL: ${desc} — list should NOT contain \"${element}\", got ${result}"
    all_checks_passed=false
  else
    echo "PASS: ${desc}"
  fi
}

nix_eval_list_empty() {
  local desc="$1" expr="$2"
  local result
  result="$(REPO_ROOT="${repo_root}" nix eval --impure --json --expr "${expr}" 2>/dev/null || echo "__ERROR__")"
  if [[ "${result}" == "[ ]" ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} — expected empty list, got ${result}"
    all_checks_passed=false
  fi
}

# ============================================================
# Shared helper: build nat output from mock data
# ============================================================
run_nat() {
  # Arguments: siteAttrsExpr, interfacesExpr, nat44Expr, nat66Expr
  local site_expr="$1" ifaces_expr="$2" nat44_expr="$3" nat66_expr="${4:-{}}"
  nix eval --impure --json --expr "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = ${site_expr};
      interfaceRecords = ${ifaces_expr};
      target = {
        egressIntent = {
          exit = true;
          uplinks = [ \"uplink0\" ];
          nat44 = ${nat44_expr};
          nat66 = ${nat66_expr};
        };
      };
      overlayNames = [];
    in
    buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; }
  " 2>/dev/null || echo "__ERROR__"
}

# ============================================================
# Predicate 1: P2P interface prefix included in fabric prefixes
# ============================================================
echo "--- Predicate 1: P2P fabric prefix inclusion ---"

nix_eval_list_contains \
  "P2P /31 prefix in masqueradeFabricPrefixes4" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = {};
      interfaceRecords = [
        {
          sourceKind = \"p2p\";
          runtimeIfName = \"eth1\";
          addr4 = \"10.0.1.0/31\";
          upstream = \"core\";
        }
        {
          sourceKind = \"wan\";
          runtimeIfName = \"eth0\";
          addr4 = \"203.0.113.10/32\";
          upstream = \"uplink0\";
          hostUplink.ipv4.address = \"203.0.113.10\";
        }
      ];
      target = {
        egressIntent = {
          exit = true;
          uplinks = [ \"uplink0\" ];
          nat44.uplink0.mode = \"masquerade\";
        };
      };
      overlayNames = [];
      result = buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; };
    in
      result.masqueradeFabricPrefixes4
  " \
  "10.0.1.0/31"

# ============================================================
# Predicate 2: Tenant interface prefix included in fabric prefixes
# ============================================================
echo "--- Predicate 2: Tenant fabric prefix inclusion ---"

nix_eval_list_contains \
  "Tenant /24 prefix in masqueradeFabricPrefixes4" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = {};
      interfaceRecords = [
        {
          sourceKind = \"tenant\";
          runtimeIfName = \"lan0\";
          addr4 = \"10.0.2.0/24\";
          upstream = \"tenant-a\";
        }
        {
          sourceKind = \"wan\";
          runtimeIfName = \"eth0\";
          addr4 = \"203.0.113.10/32\";
          upstream = \"uplink0\";
          hostUplink.ipv4.address = \"203.0.113.10\";
        }
      ];
      target = {
        egressIntent = {
          exit = true;
          uplinks = [ \"uplink0\" ];
          nat44.uplink0.mode = \"masquerade\";
        };
      };
      overlayNames = [];
      result = buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; };
    in
      result.masqueradeFabricPrefixes4
  " \
  "10.0.2.0/24"

# ============================================================
# Predicate 3: /32 host routes excluded from fabric prefixes
# ============================================================
echo "--- Predicate 3: /32 host route exclusion ---"

nix_eval_list_not_contains \
  "WAN /32 host route NOT in fabric prefixes" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = {};
      interfaceRecords = [
        {
          sourceKind = \"wan\";
          runtimeIfName = \"eth0\";
          addr4 = \"203.0.113.10/32\";
          upstream = \"uplink0\";
          hostUplink.ipv4.address = \"203.0.113.10\";
        }
      ];
      target = {
        egressIntent = {
          exit = true;
          uplinks = [ \"uplink0\" ];
          nat44.uplink0.mode = \"masquerade\";
        };
      };
      overlayNames = [];
      result = buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; };
    in
      result.masqueradeFabricPrefixes4
  " \
  "203.0.113.10/32"

# Also test with a p2p /32 (should be excluded as host route)
nix_eval_list_not_contains \
  "P2P /32 host route excluded from fabric prefixes" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = {};
      interfaceRecords = [
        {
          sourceKind = \"p2p\";
          runtimeIfName = \"eth1\";
          addr4 = \"10.0.1.1/32\";
          upstream = \"core\";
        }
        {
          sourceKind = \"wan\";
          runtimeIfName = \"eth0\";
          addr4 = \"203.0.113.10/32\";
          upstream = \"uplink0\";
          hostUplink.ipv4.address = \"203.0.113.10\";
        }
      ];
      target = {
        egressIntent = {
          exit = true;
          uplinks = [ \"uplink0\" ];
          nat44.uplink0.mode = \"masquerade\";
        };
      };
      overlayNames = [];
      result = buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; };
    in
      result.masqueradeFabricPrefixes4
  " \
  "10.0.1.1/32"

# ============================================================
# Predicate 4: Seeded negative — WAN prefix excluded from fabric prefixes
# ============================================================
echo "--- Predicate 4: Seeded negative — WAN prefix excluded ---"

nix_eval_bool \
  "WAN subnet NOT in masqueradeFabricPrefixes4 when p2p is present" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = {};
      interfaceRecords = [
        {
          sourceKind = \"wan\";
          runtimeIfName = \"eth0\";
          addr4 = \"10.11.0.50/24\";
          upstream = \"uplink0\";
          hostUplink.ipv4.address = \"10.11.0.50\";
        }
        {
          sourceKind = \"p2p\";
          runtimeIfName = \"eth1\";
          addr4 = \"10.0.1.0/31\";
          upstream = \"core\";
        }
      ];
      target = {
        egressIntent = {
          exit = true;
          uplinks = [ \"uplink0\" ];
          nat44.uplink0.mode = \"masquerade\";
        };
      };
      overlayNames = [];
      result = buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; };
      prefixes = result.masqueradeFabricPrefixes4;
    in
      (builtins.elem \"10.0.1.0/31\" prefixes) && !(builtins.elem \"10.11.0.0/24\" prefixes)
  " \
  "true"

# ============================================================
# Predicate 5: Overlay interface prefix excluded
# ============================================================
echo "--- Predicate 5: Overlay prefix excluded from fabric prefixes ---"

nix_eval_bool \
  "Overlay subnet NOT in masqueradeFabricPrefixes4" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = {};
      interfaceRecords = [
        {
          sourceKind = \"overlay\";
          runtimeIfName = \"nebula0\";
          addr4 = \"172.16.0.1/24\";
          upstream = \"nebula\";
        }
        {
          sourceKind = \"wan\";
          runtimeIfName = \"eth0\";
          addr4 = \"203.0.113.10/32\";
          upstream = \"uplink0\";
          hostUplink.ipv4.address = \"203.0.113.10\";
        }
      ];
      target = {
        egressIntent = {
          exit = true;
          uplinks = [ \"uplink0\" ];
          nat44.uplink0.mode = \"masquerade\";
        };
      };
      overlayNames = [];
      result = buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; };
    in
      result.masqueradeFabricPrefixes4 == [ ]
  " \
  "true"

# ============================================================
# Predicate 6: Combined masqueradeSourcePrefixes4 includes tenant + fabric
# ============================================================
echo "--- Predicate 6: Combined source prefixes include tenant and fabric ---"

nix_eval_bool \
  "masqueradeSourcePrefixes4 contains tenant prefix and fabric prefix" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = {
        domains.tenants = [
          { name = \"tenant-a\"; ipv4 = \"10.20.10.0/24\"; }
        ];
      };
      interfaceRecords = [
        {
          sourceKind = \"p2p\";
          runtimeIfName = \"eth1\";
          addr4 = \"10.0.1.0/31\";
          upstream = \"core\";
        }
        {
          sourceKind = \"wan\";
          runtimeIfName = \"eth0\";
          addr4 = \"203.0.113.10/32\";
          upstream = \"uplink0\";
          hostUplink.ipv4.address = \"203.0.113.10\";
        }
      ];
      target = {
        egressIntent = {
          exit = true;
          uplinks = [ \"uplink0\" ];
          nat44.uplink0.mode = \"masquerade\";
        };
      };
      overlayNames = [];
      result = buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; };
      prefixes = result.masqueradeSourcePrefixes4;
    in
      (builtins.elem \"10.20.10.0/24\" prefixes) && (builtins.elem \"10.0.1.0/31\" prefixes)
  " \
  "true"

# ============================================================
# Predicate 7: Routed internal fabric prefixes behind the egress core are included
# ============================================================
echo "--- Predicate 7: Routed fabric prefix inclusion ---"

nix_eval_bool \
  "masqueradeSourcePrefixes4 contains routed internal p2p prefixes but excludes default and host routes" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = {
        domains.tenants = [
          { name = \"tenant-a\"; ipv4 = \"10.20.10.0/24\"; }
        ];
      };
      interfaceRecords = [
        {
          sourceKind = \"p2p\";
          runtimeIfName = \"core-transit\";
          addr4 = \"10.0.1.2/31\";
          upstream = \"selector\";
          routes.ipv4 = [
            { dst = \"0.0.0.0/0\"; proto = \"default\"; via4 = \"10.0.1.3\"; }
            { dst = \"10.0.1.0/31\"; proto = \"internal\"; via4 = \"10.0.1.3\"; }
            { dst = \"10.0.1.4/31\"; proto = \"internal\"; via4 = \"10.0.1.3\"; }
            { dst = \"10.19.0.2/32\"; proto = \"internal\"; via4 = \"10.0.1.3\"; }
          ];
        }
        {
          sourceKind = \"wan\";
          runtimeIfName = \"uplink0\";
          addr4 = \"198.51.100.10/32\";
          upstream = \"uplink0\";
          hostUplink.ipv4.address = \"198.51.100.10\";
          routes.ipv4 = [
            { dst = \"198.51.100.0/24\"; proto = \"connected\"; }
          ];
        }
      ];
      target = {
        egressIntent = {
          exit = true;
          uplinks = [ \"uplink0\" ];
          nat44.uplink0.mode = \"masquerade\";
        };
      };
      overlayNames = [];
      result = buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; };
      prefixes = result.masqueradeSourcePrefixes4;
    in
      (builtins.elem \"10.0.1.0/31\" prefixes)
      && (builtins.elem \"10.0.1.4/31\" prefixes)
      && (builtins.elem \"10.0.1.2/31\" prefixes)
      && !(builtins.elem \"0.0.0.0/0\" prefixes)
      && !(builtins.elem \"10.19.0.2/32\" prefixes)
      && !(builtins.elem \"198.51.100.0/24\" prefixes)
  " \
  "true"

# ============================================================
# Predicate 8: No fabric prefixes when NAT is not enabled
# ============================================================
echo "--- Predicate 8: No fabric prefixes without NAT configuration ---"

nix_eval_bool \
  "masqueradeFabricPrefixes4 empty when nat44 not configured" \
  "
    let
      helpers = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/cpm-contract-support.nix\") { lib = import <nixpkgs/lib>; };
      buildNatIntent = import (builtins.getEnv \"REPO_ROOT\" + \"/src/cpm/firewall-intent/nat.nix\") { inherit helpers; };
      siteAttrs = {};
      interfaceRecords = [
        {
          sourceKind = \"p2p\";
          runtimeIfName = \"eth1\";
          addr4 = \"10.0.1.0/31\";
          upstream = \"core\";
        }
        {
          sourceKind = \"wan\";
          runtimeIfName = \"eth0\";
          addr4 = \"203.0.113.10/32\";
          upstream = \"uplink0\";
          hostUplink.ipv4.address = \"203.0.113.10\";
        }
      ];
      target = {
        egressIntent = {
          exit = false;
          uplinks = [];
        };
      };
      overlayNames = [];
      result = buildNatIntent { inherit siteAttrs interfaceRecords target overlayNames; };
    in
      result.masqueradeFabricPrefixes4 == [ ] && result.masqueradeFabricPrefixes6 == [ ] && result.enabled == false
  " \
  "true"

# ============================================================
# Report
# ============================================================
echo ""
if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS: All FS-380-HDS-020-SDS-010-SMS-100 CPM NAT fabric prefix inclusion checks passed."
  exit 0
else
  echo "FAIL: One or more checks failed."
  exit 1
fi
