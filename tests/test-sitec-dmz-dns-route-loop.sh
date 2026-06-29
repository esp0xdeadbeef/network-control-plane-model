#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-DNS-SITEC-LOOP-001
# GAMP-SCOPE: software-module-test
set -euo pipefail
# LAB-SMT-ID: LAB-SMT-007
# LAB-SMT-SCOPE: examples-only; see network-labs/tests/SMT.md

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
    policyInterfaces =
      built.control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-policy".effectiveRuntimeRealization.interfaces;
    routesFor = ifName: interfaces.${ifName}.routes.ipv4 or [ ];
    policyRoutesFor = ifName: policyInterfaces.${ifName}.routes.ipv4 or [ ];
    routesToDmzDns =
      ifName:
      builtins.filter
        (route: (route.dst or null) == "10.90.10.0/24")
        (routesFor ifName);
    policyRoutesToDmzDns =
      ifName:
      builtins.filter
        (route: (route.dst or null) == "10.90.10.0/24")
        (policyRoutesFor ifName);
    viaSet = ifName: builtins.map (route: route.via4 or "") (routesToDmzDns ifName);
    policyHasDmzEwServiceRoute =
      builtins.any
        (route:
          (route.via4 or null) == "10.80.0.8"
          && (route.policyOnly or false) == true
          && (((route.intent or { }).kind or null) == "service-dns-reachability")
          && (((route.intent or { }).source or null) == "service-ingress-lane")
          && (((route.lane or { }).access or null) == "c-router-access-dmz")
          && (((route.lane or { }).uplink or null) == "east-west"))
        (policyRoutesToDmzDns "p2p-c-router-downstream-selector-c-router-policy--access-c-router-access-dmz");
    coreNebulaVia = viaSet "p2p-c-router-nebula-core-c-router-upstream-selector";
  in
    if builtins.elem "172.31.254.1" coreNebulaVia then
      throw "site-c upstream-selector must not send the local dmz DNS/provider prefix back to WAN from the core-nebula ingress lane."
    else if !policyHasDmzEwServiceRoute then
      throw "site-c policy router must keep the 10.90.10.0/24 DNS service route on downstream-dmz with the east-west DMZ ingress lane"
    else
      true
' | grep -qx true

echo "PASS sitec-dmz-dns-route-loop"
