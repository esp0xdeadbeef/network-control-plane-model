#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-RUNTIME-ROUTE-IDENTITY-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
export REPO_ROOT="${repo_root}"

nix eval --impure --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    routeIdentity = import (repoRoot + "/src/cpm/Site/build-data/runtime-route-identity.nix") {
      attrsOrEmpty = value: if builtins.isAttrs value then value else { };
      defaultDst = family: if family == 4 then "0.0.0.0/0" else "::/0";
    };

    separatedA = {
      dst = "10.0.0.0/24|overlay";
      intent = {
        kind = "service";
        source = "policy";
      };
      lane = {
        access = "access";
        uplink = "wan";
      };
    };
    separatedB = {
      dst = "10.0.0.0/24";
      intent = {
        kind = "overlay|service";
        source = "policy";
      };
      lane = {
        access = "access";
        uplink = "wan";
      };
    };
    missingDst = {
      intent.kind = "service";
      lane.access = "access";
    };
    emptyDst = missingDst // {
      dst = "";
    };
    malformedNestedValues = {
      dst = "10.10.0.0/24";
      intent = "not-an-attrset";
      lane = [ "not" "an" "attrset" ];
    };

    unique = routeIdentity.uniqueRoutes 4 [
      separatedA
      separatedB
      missingDst
      emptyDst
      malformedNestedValues
      malformedNestedValues
    ];

    # FS-315: two modeled allow tuples that differ only by traffic class,
    # protocol, port or service are distinct selection authorities even when
    # they share a destination prefix, address family and next hop.  Their
    # per-relation policy routes must not collapse into one route identity.
    sharedDestinationRelationA = {
      dst = "10.3.60.10/32";
      proto = "internal";
      policyOnly = true;
      relationId = "allow-wan-to-s-gameserver-mc-test";
      via4 = "10.10.0.53";
      intent = {
        kind = "relation-policy-reachability";
        source = "public-ingress-tuple-authority";
        direction = "forward";
        policyStateOwner = "policy";
      };
    };
    sharedDestinationRelationB = sharedDestinationRelationA // {
      relationId = "allow-wan-to-s-gameserver-valheim";
    };
    sharedDestinationRoutes = routeIdentity.uniqueRoutes 4 [
      sharedDestinationRelationA
      sharedDestinationRelationB
    ];
  in
    if builtins.length unique != 5 then
      throw "runtime route identity key collapsed distinct route identities"
    else if builtins.length sharedDestinationRoutes != 2 then
      throw "runtime route identity key collapsed distinct shared-destination relation authorities (FS-315)"
    else
      true
' >/dev/null

echo "PASS runtime-route-identity-key"
