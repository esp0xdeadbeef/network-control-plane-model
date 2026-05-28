#!/usr/bin/env bash
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
    inputPath = labs + "/examples/s-router-overlay-dns-lane-policy/intent.nix";
    inventoryPath = labs + "/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix";
  };
  core = built.control_plane_model.data.esp0xdeadbeef."site-c"
    .runtimeTargets."esp0xdeadbeef-site-c-c-router-core";
  rules = core.forwardingIntent.rules or [ ];
  hasSource = source: rule:
    builtins.any
      (entry: (entry.prefix or null) == source || entry == source)
      (rule.sourcePrefixes or [ ]);
  dnsRuleFor = family: source:
    builtins.any
      (rule:
        (rule.intent.kind or null) == "dns-service-public-egress"
        && (rule.intent.source or null) == "dns-service"
        && (rule.action or null) == "accept"
        && (rule.trafficType or null) == "dns"
        && (rule.fromInterface or null) == "upstream"
        && (rule.toInterface or null) == "wan"
        && (rule.family or null) == family
        && hasSource source rule)
      rules;
in
  dnsRuleFor 4 "10.90.10.1"
  && dnsRuleFor 6 "fd42:dead:cafe:10::1"
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS core-dns-service-public-egress-forwarding"
else
  echo "FAIL core-dns-service-public-egress-forwarding" >&2
  exit 1
fi
