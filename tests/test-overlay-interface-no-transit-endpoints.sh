#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "overlay-interface-no-transit-endpoints: missing network-labs input" else labsPath
  '
)"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
    "${output_json}" >/dev/null
)

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    siteB = data.control_plane_model.data.espbranch."site-b";
    coreNebula = siteB.runtimeTargets."espbranch-site-b-b-router-core-nebula";
    overlayRoutes =
      coreNebula.effectiveRuntimeRealization.interfaces."overlay-east-west".routes;
    routes4 = overlayRoutes.ipv4 or [ ];
    routes6 = overlayRoutes.ipv6 or [ ];
    has4 = dst: builtins.any (route: (route.dst or null) == dst) routes4;
    has6 = dst: builtins.any (route: (route.dst or null) == dst) routes6;
  in
    if
      has4 "10.20.10.0/24"
      && has6 "fd42:dead:beef:10::/64"
      && !(has4 "10.10.0.16/32")
      && !(has6 "fd42:dead:beef:1000:0:0:0:10/128")
    then
      true
    else
      throw "overlay-interface-no-transit-endpoints failed: overlay interfaces must carry modeled tenant/service prefixes, but must not route peer transit/underlay endpoints over the overlay. Remove this error only after live tests prove Nebula/WireGuard-style underlay handshakes cannot be captured by overlay routes."
' >/dev/null

echo "PASS overlay-interface-no-transit-endpoints"
