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
  siteC = built.control_plane_model.data.esp0xdeadbeef."site-c";
  upstream = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector";
  dns = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-access-dmz".services.dns;
  upstreamIfs = upstream.effectiveRuntimeRealization.interfaces;
  upstreamRules = upstream.forwardingIntent.rules or [ ];

  hasRoute6 = routes: dst: via:
    builtins.any (route: (route.dst or null) == dst && (route.via6 or null) == via) routes;
  hasRule = rules: relation: fromIf: toIf:
    builtins.any
      (rule:
        (rule.relationId or null) == relation
        && (rule.fromInterface or null) == fromIf
        && (rule.toInterface or null) == toIf
        && (rule.action or null) == "accept")
      rules;
in
  builtins.elem "10.90.10.0/24" (dns.allowFrom or [ ])
  && builtins.elem "fd42:dead:cafe:10::/64" (dns.allowFrom or [ ])
  && hasRoute6 (upstreamIfs."p2p-c-router-nebula-core-c-router-upstream-selector".routes.ipv6 or [ ]) "::/0" "fd42:dead:cafe:1000:0:0:0:a"
  && hasRoute6 (upstreamIfs."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-client--uplink-east-west".routes.ipv6 or [ ]) "::/0" "fd42:dead:cafe:1000:0:0:0:a"
  && hasRule upstreamRules "allow-east-west-to-sitec-dmz-dns" "core-nebula" "pol-dmz-ew"
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS sitec-overlay-service-ingress"
else
  echo "FAIL sitec-overlay-service-ingress" >&2
  exit 1
fi
