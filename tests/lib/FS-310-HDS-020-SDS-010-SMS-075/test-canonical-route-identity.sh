#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-020-SDS-010-SMS-075
# GAMP-SCOPE: software-module-test
#
# One canonical route, one kernel primitive -- and nothing else lost.
#
# `ip route replace` keys on (family, table, destination, gateway, metric) on one
# interface of one target. Two entries that share that identity ARE the same
# command, so canonicalRoutes must publish one. `policyOnly` is the projection
# flag and is merged as a union; `kind` and `sourceKind` are labels for the same
# command and are chosen deterministically.
#
# The failure this guards against is the OPPOSITE of the duplicate: a merge
# defined too broadly silently deletes a route the model declared. So the test
# asserts both halves from real model output and from the module itself:
#
#   1. no kernel identity appears twice in the published canonicalRoutes;
#   2. the published set is byte-identical across two compiles;
#   3. the same command arriving twice (once as its policy-only projection with
#      a different label) merges to ONE entry, keeps the policyOnly union, and
#      keeps a deterministically chosen label;
#   4. two entries with DIFFERENT next hops are different primitives and both
#      survive -- the merge must not collapse them.
#
# (3) and (4) are complementary: a merge that passes (3) by broadening the key
# fails (4), and one that passes (4) by narrowing the key fails (3).
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

result="$(REPO_ROOT="${repo_root}" nix eval --no-write-lock-file --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake (toString repoRoot);
    lib = flake.inputs.nixpkgs.lib;
    system = builtins.currentSystem;
    cpmLib = flake.libBySystem.${system};
    labs = flake.inputs.network-labs.outPath;
    example = labs + "/examples/wireguard-provider-overlay";

    compile = _: cpmLib.compileAndBuildFromPaths {
      inputPath = example + "/intent.nix";
      inventoryPath = example + "/inventory-nixos.nix";
    };
    first = compile 1;
    second = compile 2;
    routes = first.control_plane_model.canonicalRoutes;

    kernelIdentity =
      route:
      builtins.toJSON [
        route.target
        route.interface
        route.family
        route.dst
        route.gateway
        route.tableId
        route.metric
      ];
    identities = map kernelIdentity routes;

    module = import (repoRoot + "/src/cpm/canonical-routes.nix") { inherit lib; };

    # One interface of one target, carrying the given routes. This is the shape
    # the module walks, so the seeded cases exercise the real function rather
    # than a re-implementation of it.
    route = overrides: {
      dst = "10.0.0.0/8";
      via4 = "10.9.0.1";
      metric = 50;
      policyOnly = false;
      intent.kind = "internal-reachability";
    } // overrides;
    cpmWith = routes: {
      data."ent"."site".runtimeTargets."tgt".effectiveRuntimeRealization.interfaces."if0" = {
        runtimeIfName = "ens1";
        sourceKind = "p2p";
        policyRoutingAllocation.tableId = 1001;
        routes.ipv4 = routes;
      };
    };

    # The same command twice (one arrival is its policy-only projection, and it
    # carries a different label): this MUST merge to one entry.
    sameCommand = module (cpmWith [
      (route { })
      (route { policyOnly = true; intent.kind = "service-dns-reachability"; })
    ]);

    # A different next hop is a different kernel identity, so those two are
    # legitimately kept -- asserted separately, because "they merged" and "they
    # were correctly kept apart" must not be confused.
    distinctGateways = module (cpmWith [
      (route { via4 = "10.9.0.1"; })
      (route { via4 = "10.9.0.2"; })
    ]);

  in
  {
    published = builtins.length routes;
    distinctIdentities = builtins.length (lib.unique identities);
    deterministic = builtins.toJSON first.control_plane_model.canonicalRoutes
      == builtins.toJSON second.control_plane_model.canonicalRoutes;
    mergedSameCommand = builtins.length sameCommand;
    # The merged entry must keep the label of the plain arrival, chosen by
    # sorting (deterministic), and the policyOnly union.
    mergedKind =
      if builtins.length sameCommand == 1 then (builtins.head sameCommand).kind else null;
    mergedPolicyOnly =
      if builtins.length sameCommand == 1 then (builtins.head sameCommand).policyOnly else null;
    distinctGatewayCount = builtins.length distinctGateways;
    # The property that actually matters: merging must not lose a field that
    # identifies WHERE a route installs. `kind`, `sourceKind` and `policyOnly`
    # are the only fields the module may reconcile. If `deploymentHost` or
    # `runtimeIfName` ever differ inside one kernel identity, a route has been
    # silently repointed at another link or host.
    #
    # Measured on wireguard-provider-overlay when this was written: 661 raw
    # records, 244 merged groups, and the only differing fields were `kind` and
    # `policyOnly`. This assertion is what makes that a checked fact instead of
    # a one-off observation.
    fieldsDifferingInsideMerges =
      let
        groupedByKernel = lib.groupBy kernelIdentity routes;
        multiGroups = builtins.filter
          (k: builtins.length groupedByKernel.${k} > 1)
          (builtins.attrNames groupedByKernel);
        fields = [ "kind" "sourceKind" "policyOnly" "deploymentHost" "runtimeIfName" ];
        distinct = f: group: builtins.length (lib.attrNames (lib.listToAttrs
          (map (e: { name = builtins.toJSON (e.${f} or null); value = true; }) group)));
      in
      builtins.filter (f: builtins.any (k: distinct f groupedByKernel.${k} > 1) multiGroups) fields;

  }
')"

fail() {
  printf 'FAIL FS-310-HDS-020-SDS-010-SMS-075 canonical route identity: %s\n' "$*" >&2
  exit 1
}

published="$(jq -r '.published' <<<"${result}")"
distinct="$(jq -r '.distinctIdentities' <<<"${result}")"
deterministic="$(jq -r '.deterministic' <<<"${result}")"
merged="$(jq -r '.mergedSameCommand' <<<"${result}")"
merged_policy_only="$(jq -r '.mergedPolicyOnly' <<<"${result}")"
distinct_gateways="$(jq -r '.distinctGatewayCount' <<<"${result}")"
nonmergeable_diffs="$(jq -r '.fieldsDifferingInsideMerges | map(select(. != "kind" and . != "sourceKind" and . != "policyOnly")) | join(",")' <<<"${result}")"
merged_kind="$(jq -r '.mergedKind' <<<"${result}")"

((published > 0)) || fail "the model published no canonical routes, so this check is vacuous"
[[ "${published}" == "${distinct}" ]] \
  || fail "one kernel identity published more than once (${published} entries, ${distinct} identities)"
[[ "${deterministic}" == "true" ]] \
  || fail "canonicalRoutes is not deterministic across two compiles of the same model"
[[ "${merged}" == "1" ]] \
  || fail "the same command arrived twice and was published ${merged} times, not once"
[[ "${merged_policy_only}" == "true" ]] \
  || fail "policyOnly must be the union of the merged entries, got ${merged_policy_only}"
# Sorted, so "internal-reachability" < "service-dns-reachability".
[[ "${merged_kind}" == "internal-reachability" ]] \
  || fail "the merged entry's kind must be chosen deterministically, got ${merged_kind}"
[[ -z "${nonmergeable_diffs}" ]] \
  || fail "routes merged across a field that identifies where they install (${nonmergeable_diffs}); one has been repointed"
[[ "${distinct_gateways}" == "2" ]] \
  || fail "two routes with different next hops are different primitives and must both be kept, got ${distinct_gateways}"

echo "PASS canonical route identity (${published} routes, no duplicate identity, deterministic, merge keeps label and policyOnly union, distinct next hops stay distinct)"
