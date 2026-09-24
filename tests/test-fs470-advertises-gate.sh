#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-FS470-ADVERTISES-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
export REPO_ROOT="${repo_root}"

nix eval --impure --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake ("path:" + repoRoot);
    lib = flake.inputs.nixpkgs.lib;
    addRoutes = import (repoRoot + "/src/cpm/Site/build-data/core-tenant-return-routes.nix") {
      inherit lib;
    };

    fabricIface = {
      sourceKind = "p2p";
      addr4 = "10.1.0.0/31";
      backingRef.lane.uplink = "fabric";
      routes = { };
    };
    coreTarget = {
      role = "core";
      effectiveRuntimeRealization.interfaces.p2p0 = fabricIface;
    };

    routesOf = result:
      result.core.effectiveRuntimeRealization.interfaces.p2p0.routes.ipv4 or [ ];

    declared = addRoutes {
      core = coreTarget // {
        advertises = [
          "10.20.10.0/24"
          "fd42:dead:beef:10::/64"
        ];
      };
    };
    undeclared = addRoutes { core = coreTarget; };
    natOnly = addRoutes {
      core = coreTarget // {
        natIntent = {
          masqueradeSourcePrefixes4 = [ "10.20.10.0/24" ];
        };
      };
    };

    expectedRoutes = [
      {
        dst = "10.20.10.0/24";
        proto = "internal";
        via4 = "10.1.0.1";
        intent = {
          kind = "internal-reachability";
          source = "tenant-subnet-return";
        };
      }
    ];
  in
    if routesOf declared != expectedRoutes then
      throw "FS-470: a declared advertisement must install one IPv4 return route per advertised prefix"
    else if builtins.length (routesOf undeclared) != 0 then
      throw "FS-470: a node that declares no advertisement must install no return route"
    else if builtins.length (routesOf natOnly) != 0 then
      throw "FS-470: the NAT source set must not be inferred as an advertisement"
    else
      true
' >/dev/null

echo "PASS fs470-advertises-gate"
