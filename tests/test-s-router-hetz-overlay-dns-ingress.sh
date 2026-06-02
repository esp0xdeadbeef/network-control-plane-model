#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-OVERLAY-HETZ-DNS-INGRESS-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
cd "$repo_root"

expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  labs = flake.inputs.network-labs.outPath;
  built = flake.lib.${system}.compileAndBuildFromPaths {
    inputPath = labs + "/sat/intent.nix";
    inventoryPath = labs + "/sat/inventory.nix";
  };
  site = built.control_plane_model.data.esp.hetz;
  upstream = site.runtimeTargets."esp-hetz-router-upstream";
  upstreamIfs = upstream.effectiveRuntimeRealization.interfaces;
  upstreamRules = upstream.forwardingIntent.rules or [ ];

  hasRule = relation: fromIf: toIf:
    builtins.any
      (rule:
        (rule.relationId or null) == relation
        && (rule.fromInterface or null) == fromIf
        && (rule.toInterface or null) == toIf
        && (rule.action or null) == "accept")
      upstreamRules;
  hasRoute4 = routes: dst: via:
    builtins.any (route: (route.dst or null) == dst && (route.via4 or null) == via) (routes.ipv4 or [ ]);
in
  hasRule "allow-overlay-to-hostile-public-dns" "nebula-core" "pol-dmz-ew"
  && hasRoute4
    (upstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes or { })
    "10.90.10.0/24"
    "10.80.0.14"
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS s-router-hetz-overlay-dns-ingress"
else
  echo "FAIL s-router-hetz-overlay-dns-ingress" >&2
  exit 1
fi
