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
  dns = built.control_plane_model.data.esp.hetz
    .runtimeTargets."esp-hetz-router-access-dmz".services.dns;
  hasAll = expected: actual:
    builtins.all (value: builtins.elem value actual) expected;
in
  hasAll [ "1.1.1.1" "9.9.9.9" ] (dns.forwarders or [ ])
  && hasAll [ "2606:4700:4700::1111" "2620:fe::fe" ] (dns.forwarders or [ ])
  && builtins.elem "explicit-egress-default" (dns.allowedUpstreamClasses or [ ])
  && (dns.blockDirectEgress or false)
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS lab-sigma-dns-service-wan-forwarders"
else
  echo "FAIL lab-sigma-dns-service-wan-forwarders" >&2
  exit 1
fi
