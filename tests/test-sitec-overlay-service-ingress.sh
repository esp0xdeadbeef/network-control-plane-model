#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-OVERLAY-SITEC-INGRESS-001
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
    inputPath = labs + "/examples/s-router-overlay-dns-lane-policy/intent.nix";
    inventoryPath = labs + "/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix";
  };
  siteC = built.control_plane_model.data.esp0xdeadbeef."site-c";
  upstream = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector";
  policy = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-policy";
  nebulaCore = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-nebula-core";
  dns = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-access-dmz".services.dns;
  upstreamIfs = upstream.effectiveRuntimeRealization.interfaces;
  policyIfs = policy.effectiveRuntimeRealization.interfaces;
  nebulaIfs = nebulaCore.effectiveRuntimeRealization.interfaces;
  upstreamRules = upstream.forwardingIntent.rules or [ ];

  hasRoute6 = routes: dst: via:
    builtins.any (route: (route.dst or null) == dst && (route.via6 or null) == via) routes;
  hasRoute4 = routes: dst: via:
    builtins.any (route: (route.dst or null) == dst && (route.via4 or null) == via) routes;
  hasOverlayLinkRoute4 = routes: dst:
    builtins.any
      (route:
        (route.dst or null) == dst
        && (route.scope or null) == "link"
        && (route.proto or null) == "overlay"
        && ((route.intent or { }).kind or null) == "overlay-node-reachability")
      routes;
  hasOverlayLinkRoute6 = routes: dst:
    builtins.any
      (route:
        (route.dst or null) == dst
        && (route.scope or null) == "link"
        && (route.proto or null) == "overlay"
        && ((route.intent or { }).kind or null) == "overlay-node-reachability")
      routes;
  hasRule = rules: relation: fromIf: toIf:
    builtins.any
      (rule:
        (rule.relationId or null) == relation
        && (rule.fromInterface or null) == fromIf
        && (rule.toInterface or null) == toIf
        && (rule.action or null) == "accept")
      rules;
  hasDnsReturnRule = rules: relation: fromIf: toIf:
    builtins.any
      (rule:
        (rule.relationId or null) == relation
        && (rule.fromInterface or null) == fromIf
        && (rule.toInterface or null) == toIf
        && (rule.action or null) == "accept"
        && (rule.trafficType or null) == "dns"
        && builtins.elem { family = 4; prefix = "10.90.10.0/24"; } (rule.sourcePrefixes or [ ])
        && builtins.elem { family = 6; prefix = "fd42:dead:cafe:10::/64"; } (rule.sourcePrefixes or [ ]))
      rules;
in
  builtins.elem "10.90.10.0/24" (dns.allowFrom or [ ])
  && builtins.elem "fd42:dead:cafe:10::/64" (dns.allowFrom or [ ])
  && builtins.elem "100.96.10.1/32" (dns.allowFrom or [ ])
  && builtins.elem "fd42:dead:beef:ee::1/128" (dns.allowFrom or [ ])
  && hasRoute6 (upstreamIfs."p2p-c-router-nebula-core-c-router-upstream-selector".routes.ipv6 or [ ]) "::/0" "fd42:dead:cafe:1000:0:0:0:a"
  && hasRoute6 (upstreamIfs."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-client--uplink-east-west".routes.ipv6 or [ ]) "::/0" "fd42:dead:cafe:1000:0:0:0:a"
  && hasRoute4 (policyIfs."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-east-west".routes.ipv4 or [ ]) "100.96.10.1/32" "10.80.0.17"
  && hasRoute6 (policyIfs."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-east-west".routes.ipv6 or [ ]) "fd42:dead:beef:ee::1/128" "fd42:dead:cafe:1000:0:0:0:11"
  && hasOverlayLinkRoute4 (nebulaIfs."overlay-east-west".routes.ipv4 or [ ]) "100.96.10.1/32"
  && hasOverlayLinkRoute6 (nebulaIfs."overlay-east-west".routes.ipv6 or [ ]) "fd42:dead:beef:ee::1/128"
  && hasRule upstreamRules "allow-east-west-to-sitec-dmz-dns" "core-nebula" "pol-dmz-ew"
  && hasDnsReturnRule upstreamRules "allow-east-west-to-sitec-dmz-dns" "pol-dmz-ew" "core-nebula"
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS sitec-overlay-service-ingress"
else
  echo "FAIL sitec-overlay-service-ingress" >&2
  exit 1
fi
