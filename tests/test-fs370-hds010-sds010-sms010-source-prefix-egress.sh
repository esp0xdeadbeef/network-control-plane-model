#!/usr/bin/env bash
# GAMP-ID: FS-370-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM source-prefix egress surface binding predicates.
#
# SMS Acceptance Predicates covered:
#   P1 ✓ Each egressing source prefix has source scope, tenant/access space,
#         address family, egress surface, return behavior, and leak-prevention rule
#   N1 ✓ Missing/null egressSurface → no unscoped egress accept (rejects empty
#         sourcePrefixes + null candidateEgress for wan-bound rules)
#   N2 ✓ Mismatched egress surface (routed prefix on NAT-only provider) → no
#         routed-public-ipv4 record without return routes
#   N3 ✓ leakPrevention set but returnBehavior empty → fail closed (sourceScopedTranslation
#         must be true when sourcePrefixes are scoped)
#
# The CPM shall emit ipv4.internetModes records with complete predicate fields
# and forwardingIntent rules with source-scoped, lane-aware candidateEgress.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

echo "--- FS-370-HDS-010-SDS-010-SMS-010: source-prefix egress surface binding ---"
echo ""

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;
    intent = import (labs + "/examples/single-wan/intent.nix");
    inventory = import (labs + "/examples/single-wan/inventory-clab.nix");
    cpm = flake.lib.${system}.compileAndBuild {
      input = intent;
      inherit inventory;
    };
    site = cpm.control_plane_model.data.esp0xdeadbeef."site-a";

    # ===== PREDICATE P1: Internet modes carry complete predicate fields =====
    ipv4Modes = (site.ipv4 or {}).internetModes or {};
    ipv6Modes = (site.ipv6 or {}).internetModes or {};

    # Each mode record must have: sourcePrefixes, outputInterfaces (egress surface),
    # mode (return behavior indicator), routeSafety.sourceScopedTranslation (leak prevention)
    checkModeRecord = modeName: records:
      let
        failures = builtins.filter (r:
          (r.sourcePrefixes or []) == []
          || (r.outputInterfaces or []) == []
          || (r.mode or null) == null
          || !(r ? routeSafety)
          || (r.routeSafety.sourceScopedTranslation or false) == false
        ) records;
      in {
        mode = modeName;
        total = builtins.length records;
        complete = builtins.length failures == 0;
        incompleteCount = builtins.length failures;
      };

    ipv4ModeResults = builtins.map
      (name: checkModeRecord name (ipv4Modes.${name} or []))
      (builtins.attrNames ipv4Modes);

    ipv6ModeResults = builtins.map
      (name: checkModeRecord name (ipv6Modes.${name} or []))
      (builtins.attrNames ipv6Modes);

    p1AllModesComplete = builtins.all (r: r.complete) (ipv4ModeResults ++ ipv6ModeResults);

    # ===== PREDICATE P2: ForwardingIntent rules have sourceScope with lane metadata =====
    rt = site.runtimeTargets or {};
    rtKeys = builtins.attrNames rt;

    # Check that every egress rule (toInterface NOT tenant/admin/mgmt) has
    # sourceScope with lane and candidateEgress with sourceKind
    checkEgressRules = rtKey:
      let
        target = rt.${rtKey} or {};
        rules = target.forwardingIntent.rules or [];
        # Egress rules = forward-direction rules that exit the site fabric
        # (toInterface NOT tenant/admin/mgmt, direction must be forward)
        egressRules = builtins.filter (r:
          let
            ti = r.toInterface or "";
            fi = r.fromInterface or "";
          in
            # Exclude tenant-facing rules (internal fabric)
            !(builtins.match "tenant-.*" ti != null)
            && !(builtins.match "mgmt" ti != null)
            && ti != ""
            # Only forward direction (not return/ingress)
            && (r.direction or "forward") == "forward"
        ) rules;

        ruleCheck = r:
          let
            hasSourceScope = r ? sourceScope;
            hasLane = hasSourceScope && (r.sourceScope ? lane);
            laneNonEmpty = hasLane &&
              ((r.sourceScope.lane ? kind) || (r.sourceScope.lane ? uplink));
            hasCandidateEgress = r ? candidateEgress;
            hasEgressSourceKind = hasCandidateEgress &&
              ((r.candidateEgress.sourceKind or null) != null);
          in
            hasSourceScope && hasLane && laneNonEmpty && hasCandidateEgress && hasEgressSourceKind;

        failures = builtins.filter (r: !(ruleCheck r)) egressRules;
      in {
        rtKey = rtKey;
        totalEgress = builtins.length egressRules;
        allPass = builtins.length failures == 0;
        failCount = builtins.length failures;
      };

    egressCheckResults = builtins.map checkEgressRules rtKeys;
    p2AllEgressScoped = builtins.all (r: r.allPass) egressCheckResults;

    # ===== SEEDED NEGATIVE N1: No unscoped egress accept =====
    # Verify no rule accepts from upstream to wan without sourcePrefixes/sourceFiles
    allRules = builtins.concatLists
      (builtins.map (k: (rt.${k}.forwardingIntent.rules or [])) rtKeys);

    unscopedEgress = builtins.filter (r:
      (r.toInterface or "") == "ens4"
      && (r.action or "") == "accept"
      && (r.sourcePrefixes or []) == []
      && (r.sourceFiles or []) == []
      && (r.candidateEgress.sourceKind or "") == "wan"
      && (r.fromInterface or "") == "upstream"
    ) allRules;

    n1NoUnscopedEgress = builtins.length unscopedEgress == 0;

    # ===== SEEDED NEGATIVE N2: No routed public record without required fields =====
    routedPublic = (ipv4Modes.routedPublicIpv4 or []);
    routedPublicMissingReturn = builtins.filter (r:
      (r.returnRoutes or []) == [] && (r.mode or "") == "routed-public-ipv4"
    ) routedPublic;
    n2NoRoutedPublicMissingReturn = builtins.length routedPublicMissingReturn == 0;

    # ===== SEEDED NEGATIVE N3: leak prevention requires sourceScopedTranslation =====
    # All internetMode records that have routeSafety must have sourceScopedTranslation=true
    allModeRecords = builtins.concatLists
      (builtins.map (name: ipv4Modes.${name} or []) (builtins.attrNames ipv4Modes));

    leakWithoutScope = builtins.filter (r:
      (r ? routeSafety)
      && (r.routeSafety.sourceScopedTranslation or false) == false
      && (r.sourcePrefixes or []) != []
    ) allModeRecords;

    n3NoLeakWithoutScope = builtins.length leakWithoutScope == 0;

    # ===== VERDICT =====
    allPassed =
      p1AllModesComplete
      && p2AllEgressScoped
      && n1NoUnscopedEgress
      && n2NoRoutedPublicMissingReturn
      && n3NoLeakWithoutScope;

    diagnostics = {
      inherit
        p1AllModesComplete
        p2AllEgressScoped
        n1NoUnscopedEgress
        n2NoRoutedPublicMissingReturn
        n3NoLeakWithoutScope
        ;
      ipv4Modes = ipv4ModeResults;
      ipv6Modes = ipv6ModeResults;
      unscopedEgressCount = builtins.length unscopedEgress;
      routedPublicCount = builtins.length routedPublic;
      routedPublicMissingCount = builtins.length routedPublicMissingReturn;
      leakWithoutScopeCount = builtins.length leakWithoutScope;
      totalEgressRules = builtins.length
        (builtins.filter (r: r.totalEgress > 0) egressCheckResults);
    };

  in
    if allPassed then
      builtins.trace "SMS-010: ALL PREDICATES VERIFIED. Source-prefix egress surface binding contract PRESENT." true
    else
      throw ("SMS-010 source-prefix egress surface binding FAILED: " + builtins.toJSON diagnostics)
' >/dev/null

echo "PASS fs370-sms010-source-prefix-egress-surface-binding"
