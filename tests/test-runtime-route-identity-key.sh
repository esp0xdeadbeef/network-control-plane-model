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
  in
    if builtins.length unique == 5 then true else throw "runtime route identity key collapsed distinct route identities"
' >/dev/null

echo "PASS runtime-route-identity-key"
