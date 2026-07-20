#!/usr/bin/env bash
# GAMP-ID: FS-370-HDS-010-SDS-010-SMS-101
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM per-lane return-path routing for policy
# and downstream-selector nodes.
#
# SMS Acceptance Predicates covered:
#   P1 ✓ Policy node per-lane routes through correct DS-facing interface
#   P2 ✓ DS node per-lane routes through correct access-facing interface
#   N1 ✓ Return path routed to wrong lane → diagnostic (seeded negative active)
#   N2 ✓ Missing per-lane return path → diagnostic (seeded negative active)
#
# The CPM shall emit per-lane routing metadata (backingRef.lane with
# access/uplink classification) and per-lane policy routes on the policy
# and downstream-selector nodes so that renderers can materialize
# correct return-path ip rules and per-lane policy tables.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

echo "--- FS-370-HDS-010-SDS-010-SMS-101: per-lane return-path routing ---"
echo ""

expect_nix_failure() {
  local label="$1"
  local expected="$2"
  local expr="$3"
  local output

  output="$(mktemp)"
  if REPO_ROOT="${repo_root}" nix eval --impure --expr "${expr}" >"${output}" 2>&1; then
    echo "FAIL ${label}: expected construction failure containing ${expected}" >&2
    rm -f "${output}"
    exit 1
  fi
  if ! grep -q "${expected}" "${output}"; then
    echo "FAIL ${label}: construction failed without ${expected}" >&2
    cat "${output}" >&2
    rm -f "${output}"
    exit 1
  fi

  rm -f "${output}"
  echo "PASS ${label}"
}

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;

    # Use single-wan example which compiles cleanly
    baseIntent = import (labs + "/examples/single-wan/intent.nix");
    baseInventory = import (labs + "/examples/single-wan/inventory-nixos.nix");

    result = flake.lib.${system}.compileAndBuild {
      input = baseIntent;
      inventory = baseInventory;
    };

    site = result.control_plane_model.data.esp0xdeadbeef."site-a";
    rt = site.runtimeTargets or {};

    # Find policy and DS runtime targets by key suffix
    rtKeys = builtins.attrNames rt;
    policyKey = builtins.head (builtins.filter (k: builtins.match ".*-policy$" k != null) rtKeys);
    dsKey = builtins.head (builtins.filter (k: builtins.match ".*-downstream-selector$" k != null) rtKeys);

    siteExists = policyKey != null && dsKey != null;

    policyRT = if policyKey != null then rt.${policyKey} else {};
    dsRT = if dsKey != null then rt.${dsKey} else {};

    policyERR = policyRT.effectiveRuntimeRealization or {};
    dsERR = dsRT.effectiveRuntimeRealization or {};

    policyIfaces = policyERR.interfaces or {};
    dsIfaces = dsERR.interfaces or {};

    # ===== PREDICATE P1: Policy node has per-lane DS-facing interfaces with lane metadata =====
    policyDSFacing = builtins.filter
      (n: builtins.match ".*downstream.*policy.*access.*" n != null)
      (builtins.attrNames policyIfaces);

    policyDSFacingWithLane = builtins.filter
      (n:
        (policyIfaces.${n} ? backingRef && policyIfaces.${n}.backingRef ? lane)
        || (policyIfaces.${n} ? lane)
      )
      policyDSFacing;

    p1PolicyDSLanes = builtins.length policyDSFacing > 0
      && builtins.length policyDSFacingWithLane == builtins.length policyDSFacing;

    # ===== PREDICATE P2: DS node has per-lane interfaces with lane metadata and policy routes =====
    # (interface naming varies by fixture; use lane metadata presence instead of name patterns)
    dsAllWithLane = builtins.filter
      (n:
        (dsIfaces.${n} ? backingRef && dsIfaces.${n}.backingRef ? lane)
        || (dsIfaces.${n} ? lane)
      )
      (builtins.attrNames dsIfaces);

    p2DSHasLaneRoutes = builtins.length dsAllWithLane > 0;

    # ===== SEEDED NEGATIVE N1: No lane mismatch between policy and DS =====
    extractLaneAccess = iface:
      if iface ? backingRef && iface.backingRef ? lane then
        iface.backingRef.lane.access or null
      else if iface ? lane then
        iface.lane.access or null
      else null;

    # Get lane accesses from policy DS-facing interfaces
    policyLaneAccesses = builtins.filter (v: v != null)
      (builtins.map (n: extractLaneAccess (policyIfaces.${n} or {})) policyDSFacingWithLane);

    # DS policy-facing interfaces should have matching lanes
    dsPolicyFacing = builtins.filter
      (n: builtins.match ".*downstream-selector.*policy.*access.*" n != null)
      (builtins.attrNames dsIfaces);

    dsLaneAccesses = builtins.filter (v: v != null)
      (builtins.map (n: extractLaneAccess (dsIfaces.${n} or {})) dsPolicyFacing);

    # Every policy lane access MUST have a matching DS lane (no orphaned policy lanes)
    missingDSMatches = builtins.filter
      (access: !(builtins.elem access dsLaneAccesses))
      policyLaneAccesses;

    n1NoLaneMismatch = builtins.length missingDSMatches == 0;

    # ===== SEEDED NEGATIVE N2: Per-lane policy routes exist on policy and DS =====
    hasPolicyRoutes = builtins.filter
      (n:
        let
          routes = builtins.concatLists [
            (policyIfaces.${n}.routes.ipv4 or [])
            (policyIfaces.${n}.routes.ipv6 or [])
          ];
        in
        builtins.any (r: (r.policyOnly or false) == true) routes
      )
      policyDSFacingWithLane;

    n2PolicyLanesHaveRoutes = builtins.length hasPolicyRoutes > 0;

    hasDSRoutes = builtins.filter
      (n:
        let
          routes = builtins.concatLists [
            (dsIfaces.${n}.routes.ipv4 or [])
            (dsIfaces.${n}.routes.ipv6 or [])
          ];
        in
        builtins.any (r: (r.policyOnly or false) == true) routes
      )
      dsPolicyFacing;

    n2DSLanesHaveRoutes = builtins.length hasDSRoutes > 0;

    # ===== ADDITIONAL: Verify policy node has upstream-facing lanes =====
    policyUSFacing = builtins.filter
      (n: builtins.match ".*policy.*upstream-selector.*" n != null)
      (builtins.attrNames policyIfaces);

    policyUSFacingWithLane = builtins.filter
      (n:
        (policyIfaces.${n} ? backingRef && policyIfaces.${n}.backingRef ? lane)
        || (policyIfaces.${n} ? lane)
      )
      policyUSFacing;

    p3PolicyUSLanes = builtins.length policyUSFacingWithLane > 0
      && builtins.length policyUSFacingWithLane == builtins.length policyUSFacing;

    # ===== VERDICT =====
    allPassed =
      siteExists
      && p1PolicyDSLanes
      && p2DSHasLaneRoutes
      && n1NoLaneMismatch
      && n2PolicyLanesHaveRoutes
      && n2DSLanesHaveRoutes
      && p3PolicyUSLanes;

    diagnostics = {
      inherit
        siteExists
        p1PolicyDSLanes
        p2DSHasLaneRoutes
        n1NoLaneMismatch
        n2PolicyLanesHaveRoutes
        n2DSLanesHaveRoutes
        p3PolicyUSLanes
        ;
      policyDSFacingCount = builtins.length policyDSFacing;
      policyDSLaneCount = builtins.length policyDSFacingWithLane;
      dsLaneCount = builtins.length dsAllWithLane;
      missingDSMatchCount = builtins.length missingDSMatches;
      policyLaneRouteCount = builtins.length hasPolicyRoutes;
      dsLaneRouteCount = builtins.length hasDSRoutes;
      policyUSLaneCount = builtins.length policyUSFacingWithLane;
      policyKey = policyKey;
      dsKey = dsKey;
    };

  in
    if allPassed then
      builtins.trace "SMS-101: ALL PREDICATES VERIFIED. Per-lane return-path routing infrastructure PRESENT." true
    else
      throw ("SMS-101 per-lane return-path routing FAILED: " + builtins.toJSON diagnostics)
' >/dev/null

expect_nix_failure "seeded-negative-wrong-lane" "policy-ds-return-path-wrong-lane" '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake ("path:" + repoRoot);
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;
    guard = import (repoRoot + "/src/cpm/Site/build-data/policy-ds-return-path-guard.nix") {
      lib = {};
      common = {
        attrsOrEmpty = value: if builtins.isAttrs value then value else {};
        listOrEmpty = value: if builtins.isList value then value else [];
      };
    };
    result = flake.lib.${system}.compileAndBuild {
      input = import (labs + "/examples/single-wan/intent.nix");
      inventory = import (labs + "/examples/single-wan/inventory-nixos.nix");
    };
    site = result.control_plane_model.data.esp0xdeadbeef."site-a";
    runtimeTargets = site.runtimeTargets;
    policyTargetName = builtins.head (
      builtins.filter
        (name: (runtimeTargets.${name}.role or "") == "policy")
        (builtins.attrNames runtimeTargets)
    );
    target = runtimeTargets.${policyTargetName};
    realization = target.effectiveRuntimeRealization or {};
    interfaces = realization.interfaces or {};
    selectedIfName = builtins.head (
      builtins.filter
        (name:
          let
            iface = interfaces.${name};
            lane = ((iface.backingRef or {}).lane or {});
          in
          (iface.sourceKind or null) == "p2p"
          && (lane.kind or null) == "access"
          && (lane.access or null) == "s-router-access-client")
        (builtins.attrNames interfaces)
    );
    iface = interfaces.${selectedIfName};
    routes = iface.routes or {};
    mutateRoute = route:
      let intent = route.intent or {};
      in
      if (route.dst or null) == "10.20.20.0/24"
        && (route.policyOnly or false) == true
        && (route.reason or null) == "policy-table-internal-reachability"
        && (intent.source or null) == "policy-default-lane"
      then route // { lane = (route.lane or {}) // { access = "s-router-access-admin"; }; }
      else route;
    mutatedIface = iface // {
      routes = routes // {
        ipv4 = builtins.map mutateRoute (routes.ipv4 or []);
      };
    };
    mutatedTarget = target // {
      effectiveRuntimeRealization = realization // {
        interfaces = interfaces // builtins.listToAttrs [
          { name = selectedIfName; value = mutatedIface; }
        ];
      };
    };
    mutatedRuntimeTargets = runtimeTargets // builtins.listToAttrs [
      { name = policyTargetName; value = mutatedTarget; }
    ];
  in
  guard {
    tenantPrefixOwners = site.tenantPrefixOwners;
    runtimeTargets = mutatedRuntimeTargets;
  }
'

expect_nix_failure "seeded-negative-missing-return-path" "policy-ds-return-path-missing" '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake ("path:" + repoRoot);
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;
    guard = import (repoRoot + "/src/cpm/Site/build-data/policy-ds-return-path-guard.nix") {
      lib = {};
      common = {
        attrsOrEmpty = value: if builtins.isAttrs value then value else {};
        listOrEmpty = value: if builtins.isList value then value else [];
      };
    };
    result = flake.lib.${system}.compileAndBuild {
      input = import (labs + "/examples/single-wan/intent.nix");
      inventory = import (labs + "/examples/single-wan/inventory-nixos.nix");
    };
    site = result.control_plane_model.data.esp0xdeadbeef."site-a";
    runtimeTargets = site.runtimeTargets;
    policyTargetName = builtins.head (
      builtins.filter
        (name: (runtimeTargets.${name}.role or "") == "policy")
        (builtins.attrNames runtimeTargets)
    );
    target = runtimeTargets.${policyTargetName};
    realization = target.effectiveRuntimeRealization or {};
    interfaces = realization.interfaces or {};
    selectedIfName = builtins.head (
      builtins.filter
        (name:
          let
            iface = interfaces.${name};
            lane = ((iface.backingRef or {}).lane or {});
          in
          (iface.sourceKind or null) == "p2p"
          && (lane.kind or null) == "access"
          && (lane.access or null) == "s-router-access-client")
        (builtins.attrNames interfaces)
    );
    iface = interfaces.${selectedIfName};
    routes = iface.routes or {};
    keepRoute = route:
      let intent = route.intent or {};
      in
      !(
        (route.dst or null) == "10.20.20.0/24"
        && (route.policyOnly or false) == true
        && (route.reason or null) == "policy-table-internal-reachability"
        && (intent.source or null) == "policy-default-lane"
      );
    mutatedIface = iface // {
      routes = routes // {
        ipv4 = builtins.filter keepRoute (routes.ipv4 or []);
      };
    };
    mutatedTarget = target // {
      effectiveRuntimeRealization = realization // {
        interfaces = interfaces // builtins.listToAttrs [
          { name = selectedIfName; value = mutatedIface; }
        ];
      };
    };
    mutatedRuntimeTargets = runtimeTargets // builtins.listToAttrs [
      { name = policyTargetName; value = mutatedTarget; }
    ];
  in
  guard {
    tenantPrefixOwners = site.tenantPrefixOwners;
    runtimeTargets = mutatedRuntimeTargets;
  }
'

echo "PASS fs370-sms101-per-lane-return-path-routing"
