#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

nix eval --extra-experimental-features 'nix-command flakes' --impure --expr '
  let
    flake = builtins.getFlake ("path:" + toString '"$repo_root"');
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;
    built = flake.lib.${system}.compileAndBuildFromPaths {
      inputPath = labs + "/examples/s-router-overlay-dns-lane-policy/intent.nix";
      inventoryPath = labs + "/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix";
    };
    interfaces =
      built.control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector".effectiveRuntimeRealization.interfaces;
    routesFor = ifName: interfaces.${ifName}.routes.ipv4 or [ ];
    routesToDmzDns =
      ifName:
      builtins.filter
        (route: (route.dst or null) == "10.90.10.0/24")
        (routesFor ifName);
    viaSet = ifName: builtins.map (route: route.via4 or "") (routesToDmzDns ifName);
    coreNebulaVia = viaSet "p2p-c-router-nebula-core-c-router-upstream-selector";
    dmzEwVia = viaSet "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-east-west";
  in
    if builtins.elem "172.31.254.1" coreNebulaVia then
      throw "site-c upstream-selector must not send the local dmz DNS/provider prefix back to WAN from the core-nebula ingress lane."
    else if dmzEwVia != [ "10.80.0.16" ] then
      throw "site-c upstream-selector must keep exactly one 10.90.10.0/24 route via the DMZ policy lane gateway 10.80.0.16"
    else
      true
' | grep -qx true

echo "PASS sitec-dmz-dns-route-loop"
