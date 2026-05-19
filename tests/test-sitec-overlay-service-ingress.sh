#!/usr/bin/env bash
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
  built = flake.lib.${system}.compileAndBuild {
    input = flake.lib.${system}.readInput (labs + "/labs/lab-s-sigma/s-router-test-three-site/intent.nix");
    inventory = import (labs + "/labs/lab-s-sigma/s-router-test-three-site/getResolvedInventory.nix") {
      renderer = "nixos";
    };
  };
  site = built.control_plane_model.data.esp.hetz;
  upstream = site.runtimeTargets."esp-hetz-router-upstream";
  policy = site.runtimeTargets."esp-hetz-router-policy";
  nebulaCore = site.runtimeTargets."esp-hetz-router-nebula-core";
  dns = site.runtimeTargets."esp-hetz-router-access-dmz".services.dns;
  upstreamIfs = upstream.effectiveRuntimeRealization.interfaces;
  policyIfs = policy.effectiveRuntimeRealization.interfaces;
  nebulaCoreIfs = nebulaCore.effectiveRuntimeRealization.interfaces;
  upstreamRules = upstream.forwardingIntent.rules or [ ];
  policyRules = policy.forwardingIntent.rules or [ ];

  hasRoute4 = routes: dst: via:
    builtins.any (route: (route.dst or null) == dst && (route.via4 or null) == via) routes;
  hasRoute6 = routes: dst: via:
    builtins.any (route: (route.dst or null) == dst && (route.via6 or null) == via) routes;
  hasRule = rules: relation: fromIf: toIf:
    builtins.any
      (rule:
        (rule.relationId or null) == relation
        && (rule.fromInterface or null) == fromIf
        && (rule.toInterface or null) == toIf
        && (rule.action or null) == "accept"
        && (rule.trafficType or null) == "dns")
      rules;
  hasSourceRoute = routes: sourceFile: via:
    builtins.any
      (route:
        (route.sourceFile or null) == sourceFile
        && (route.via6 or null) == via
        && (route.proto or null) == "overlay"
        && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
      routes;
  hasSourceForward = rules: sourceFile: fromIf: toIf:
    builtins.any
      (rule:
        (rule.fromInterface or null) == fromIf
        && (rule.toInterface or null) == toIf
        && builtins.elem sourceFile (rule.sourceFiles or [ ])
        && ((rule.intent or { }).kind or null) == "runtime-routed-prefix-public-egress")
      rules;
in
  builtins.elem "10.20.70.0/24" (dns.allowFrom or [ ])
  && builtins.elem "fd42:dead:beef:70::/64" (dns.allowFrom or [ ])
  && hasRoute4 (nebulaCoreIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv4 or [ ]) "10.90.10.0/24" "10.80.0.11"
  && hasRoute4 (upstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv4 or [ ]) "10.90.10.0/24" "10.80.0.14"
  && hasRoute6 (upstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv6 or [ ]) "fd42:dead:cafe:0010:0000:0000:0000:0000/64" "fd42:dead:cafe:1000:0:0:0:e"
  && hasRoute4 (upstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv4 or [ ]) "10.20.70.0/24" "10.80.0.10"
  && hasRoute4 (upstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv4 or [ ]) "100.96.10.1/32" "10.80.0.10"
  && hasRoute4 (upstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv4 or [ ]) "100.96.10.3/32" "10.80.0.10"
  && hasRoute6 (upstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv6 or [ ]) "fd42:dead:beef:ee::1/128" "fd42:dead:cafe:1000:0:0:0:a"
  && hasRoute6 (upstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv6 or [ ]) "fd42:dead:beef:ee::3/128" "fd42:dead:cafe:1000:0:0:0:a"
  && hasSourceRoute (upstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv6 or [ ]) "/run/secrets/access-node-ipv6-prefix-esp-nixos-router-access-hostile" "fd42:dead:cafe:1000:0:0:0:a"
  && hasSourceForward upstreamRules "/run/secrets/access-node-ipv6-prefix-esp-nixos-router-access-hostile" "core-nebula" "core"
  && hasRule upstreamRules "allow-overlay-to-hostile-public-dns" "core-nebula" "pol-dmz-ew"
  && hasRule policyRules "allow-overlay-to-hostile-public-dns" "up-dmz-ew" "downstream-dmz"
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS sitec-overlay-service-ingress"
else
  echo "FAIL sitec-overlay-service-ingress" >&2
  exit 1
fi
