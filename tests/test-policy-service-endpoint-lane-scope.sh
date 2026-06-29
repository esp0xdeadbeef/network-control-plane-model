#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-POLICY-SERVICE-LANE-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
cd "$repo_root"

# shellcheck disable=SC2016
expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  labs = flake.inputs.network-labs.outPath;
  built = flake.lib.${system}.compileAndBuildFromPaths {
    inputPath = labs + "/examples/s-router-public-overlay-service/intent.nix";
    inventoryPath = labs + "/examples/s-router-public-overlay-service/inventory-nixos.nix";
  };
  rules =
    built.control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-policy".forwardingIntent.rules;
  serviceRules =
    builtins.filter
      (rule: (rule.relationId or null) == "allow-sitec-wan-to-dmz-nebula")
      rules;
  forwardRules =
    builtins.filter
      (rule: (rule.direction or null) == "relation-forward")
      serviceRules;
  reverseRules =
    builtins.filter
      (rule: (rule.direction or null) == "relation-reverse")
      serviceRules;
  expectedRuleFor = fromInterface: rule:
    (rule.action or null) == "accept"
    && (rule.trafficType or null) == "nebula"
    && (rule.fromInterface or null) == fromInterface
    && (rule.toInterface or null) == "downstream-dmz"
    && builtins.any
      (match: (match.proto or null) == "udp" && builtins.elem 4242 (match.dports or [ ]))
      (rule.matches or [ ])
    && builtins.any
      (match: (match.proto or null) == "tcp" && builtins.elem 4242 (match.dports or [ ]))
      (rule.matches or [ ]);
  expectedReverseRule = rule:
    (rule.action or null) == "accept"
    && (rule.trafficType or null) == "nebula"
    && (rule.fromInterface or null) == "downstream-dmz"
    && (rule.toInterface or null) == "up-dmz-wan";
in
  builtins.length forwardRules == 2
  && builtins.any (expectedRuleFor "up-client-wan") forwardRules
  && builtins.any (expectedRuleFor "up-dmz-wan") forwardRules
  && builtins.length reverseRules == 1
  && builtins.any expectedReverseRule reverseRules
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS policy-service-endpoint-lane-scope"
else
  echo "FAIL policy-service-endpoint-lane-scope" >&2
  exit 1
fi
