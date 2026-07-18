#!/usr/bin/env bash
# GAMP-ID: FS-270-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: compiler-through-CPM dual-stack route-selection contract
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
cd "${repo_root}"

report="$({
  REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
    let
      flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
      system = builtins.currentSystem;
      labs = flake.inputs.network-labs.outPath;
      traceId = "FS-270-HDS-010-SDS-010-SMS-020";
      relationId = "${traceId}__source-to-destination-icmp";
      row = labs + "/GAMP/SMT/${traceId}";
      source = import (row + "/intent.nix");
      build = inventoryPath: flake.libBySystem.${system}.compileAndBuild {
        input = source;
        inventory = import inventoryPath;
      };
      siteFor = built: built.control_plane_model.data."mini-smt".${traceId};
      targetFor = logicalName: site:
        builtins.head (builtins.filter
          (target: (target.logicalNode.name or null) == logicalName)
          (builtins.attrValues site.runtimeTargets));
      prefixRecordsFor = tenant: site:
        builtins.filter
          (record: (record.netName or null) == tenant)
          (builtins.attrValues site.tenantPrefixOwners);
      prefixFor = family: tenant: site:
        (builtins.head (builtins.filter
          (record: record.family == family)
          (prefixRecordsFor tenant site))).dst;
      interfacesFor = target:
        target.effectiveRuntimeRealization.interfaces or { };
      interfaceForLane = kind: access: target:
        builtins.head (builtins.filter
          (iface:
            let lane = (iface.backingRef or { }).lane or { };
            in (lane.kind or null) == kind && (lane.access or null) == access)
          (builtins.attrValues (interfacesFor target)));
      selectorsFor = target:
        target.effectiveRuntimeRealization.routeSelectionRules or [ ];
      routesFor = target:
        builtins.concatLists (builtins.map
          (iface:
            (iface.routes.ipv4 or [ ]) ++ (iface.routes.ipv6 or [ ]))
          (builtins.attrValues (interfacesFor target)));
      signature = rule:
        builtins.concatStringsSep "|" [
          (builtins.toString rule.family)
          rule.direction
          rule.sourcePrefix
          rule.destinationPrefix
          rule.policyStateOwner
          rule.returnBehavior
          rule.trafficType
        ];
      expectedSignatures = site:
        builtins.sort builtins.lessThan [
          "4|forward|${prefixFor 4 "source" site}|${prefixFor 4 "destination" site}|policy|symmetric|icmp"
          "6|forward|${prefixFor 6 "source" site}|${prefixFor 6 "destination" site}|policy|symmetric|icmp"
          "4|return|${prefixFor 4 "destination" site}|${prefixFor 4 "source" site}|policy|symmetric|icmp"
          "6|return|${prefixFor 6 "destination" site}|${prefixFor 6 "source" site}|policy|symmetric|icmp"
        ];
      reportFor = built:
        let
          site = siteFor built;
          target = targetFor "downstream-selector" site;
          selectors = selectorsFor target;
          relationSelectors = builtins.filter
            (rule: (rule.relationId or null) == relationId)
            selectors;
          unrelatedSelectors = builtins.filter
            (rule: (rule.relationId or null) != relationId)
            selectors;
          edgeSource = interfaceForLane "access-edge" "access-source" target;
          edgeDestination = interfaceForLane "access-edge" "access-destination" target;
          policySource = interfaceForLane "access" "access-source" target;
          policyDestination = interfaceForLane "access" "access-destination" target;
          genericPriorities = builtins.sort builtins.lessThan (builtins.map
            (iface: (iface.policyRoutingAllocation or { }).tableRulePriority or 2147483647)
            (builtins.attrValues (interfacesFor target)));
          minimumGenericPriority = builtins.head genericPriorities;
          selectorBindingValid = rule:
            let
              forward = rule.direction == "forward";
              edge = if forward then edgeSource else edgeDestination;
              policy = if forward then policySource else policyDestination;
            in
              rule.incomingInterface == edge.runtimeIfName
              && rule.policyInterface == policy.runtimeIfName
              && rule.tableId == policy.policyRoutingAllocation.tableId
              && rule.priority < minimumGenericPriority
              && rule.authority == "relation-policy-state-owner";
          routeMatches = rule: route:
            (route.relationId or null) == relationId
            && (route.intent.kind or null) == "relation-policy-reachability"
            && (route.intent.direction or null) == rule.direction
            && (route.intent.policyStateOwner or null) == rule.policyStateOwner
            && (route.returnBehavior or null) == "symmetric"
            && (route.policyOnly or false)
            && (route.dst or null) == rule.destinationPrefix
            && (
              (rule.family == 4 && (route.via4 or null) != null)
              || (rule.family == 6 && (route.via6 or null) != null)
            );
          routes = routesFor target;
          relationRoutes = builtins.filter
            (route: (route.relationId or null) == relationId)
            routes;
          forwardingRules = builtins.concatLists (builtins.map
            (runtimeTarget: runtimeTarget.forwardingIntent.rules or [ ])
            (builtins.attrValues site.runtimeTargets));
          directShortcutCandidatePresent = family: destinationPrefix:
            let
              destinationRoutes =
                if family == 4 then edgeDestination.routes.ipv4 or [ ]
                else edgeDestination.routes.ipv6 or [ ];
            in
              builtins.any
                (route:
                  (route.dst or null) == destinationPrefix
                  && !(route.policyOnly or false))
                destinationRoutes;
          signatures = builtins.sort builtins.lessThan (builtins.map signature relationSelectors);
        in
        {
          selectorCount = builtins.length relationSelectors;
          selectorBindingsValid = builtins.all selectorBindingValid relationSelectors;
          everySelectorHasPolicyRoute = builtins.all
            (rule: builtins.any (routeMatches rule) routes)
            relationSelectors;
          signaturesMatch = signatures == expectedSignatures site;
          inherit signatures;
          unrelatedSelectorCount = builtins.length unrelatedSelectors;
          relationRoutesAreBounded = builtins.all
            (route: !(builtins.elem (route.dst or null) [ "0.0.0.0/0" "::/0" ]))
            relationRoutes;
          seededDirectShortcutCandidatesPresent =
            directShortcutCandidatePresent 4 (prefixFor 4 "destination" site)
            && directShortcutCandidatePresent 6 (prefixFor 6 "destination" site);
          reverseNewFlowDenyPresent = builtins.any
            (rule:
              (rule.relationId or null) == "${traceId}__deny-reverse-new-flow"
              && (rule.action or null) == "deny"
              && !(rule ? connectionState))
            forwardingRules;
        };
      nixos = reportFor (build (row + "/inventory-nixos.nix"));
      clab = reportFor (build (row + "/inventory-clab.nix"));
    in
    {
      inherit nixos clab;
      equivalentSignatures = nixos.signatures == clab.signatures;
    }
  '
})"

if ! jq -e '
  .equivalentSignatures
  and .nixos.selectorCount == 4
  and .nixos.selectorBindingsValid
  and .nixos.everySelectorHasPolicyRoute
  and .nixos.signaturesMatch
  and .nixos.unrelatedSelectorCount == 0
  and .nixos.relationRoutesAreBounded
  and .nixos.seededDirectShortcutCandidatesPresent
  and .nixos.reverseNewFlowDenyPresent
  and .clab.selectorCount == 4
  and .clab.selectorBindingsValid
  and .clab.everySelectorHasPolicyRoute
  and .clab.signaturesMatch
  and .clab.unrelatedSelectorCount == 0
  and .clab.relationRoutesAreBounded
  and .clab.seededDirectShortcutCandidatesPresent
  and .clab.reverseNewFlowDenyPresent
' <<<"${report}" >/dev/null; then
  jq . <<<"${report}" >&2
  echo "FAIL FS-270-HDS-010-SDS-010-SMS-020: CPM does not own the complete dual-stack lateral policy-state route selection" >&2
  exit 1
fi

echo "PASS FS-270-HDS-010-SDS-010-SMS-020: CPM owns equivalent NixOS and CLAB dual-stack lateral policy-state route selection"
