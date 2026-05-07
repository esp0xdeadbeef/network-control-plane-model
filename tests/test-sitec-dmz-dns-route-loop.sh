#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    clientEwVia = viaSet "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-client--uplink-east-west";
    dmzEwVia = viaSet "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-east-west";
  in
    if coreNebulaVia != [ ] then
      throw "site-c upstream-selector must not install the local dmz DNS/provider prefix on the core-nebula ingress lane; that creates a route loop for the local Nebula lighthouse. Remove this error only after CPM keeps 10.90.10.0/24 on the DMZ policy lane."
    else if clientEwVia != [ ] then
      throw "site-c upstream-selector must not clone the local dmz DNS/provider prefix onto the client east-west lane; the internal DMZ route is already the canonical route. Remove this error only after DNS augmentation stops duplicating provider prefixes across lanes."
    else if dmzEwVia != [ "10.80.0.16" ] then
      throw "site-c upstream-selector must keep 10.90.10.0/24 via the DMZ policy lane gateway 10.80.0.16"
    else
      true
' | grep -qx true

echo "PASS sitec-dmz-dns-route-loop"
