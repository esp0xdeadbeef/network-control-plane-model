#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

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
      if labsPath == null then throw "provider-overlay-runtime-interface-name: missing network-labs input" else labsPath
  '
)"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
    "${output_json}" >/dev/null
)

OUTPUT_JSON="${output_json}" INVENTORY_PATH="${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    inventory = import (builtins.path { path = builtins.getEnv "INVENTORY_PATH"; });
    siteB = data.control_plane_model.data.espbranch."site-b";
    inventorySiteB = inventory.controlPlane.sites.espbranch."site-b";
    overlayRuntime = inventorySiteB.overlays."east-west".runtimeNodes."b-router-core-nebula";
    expectedInterface = overlayRuntime.service.interface;
    coreNebula = siteB.runtimeTargets."espbranch-site-b-b-router-core-nebula";
    overlayIface = coreNebula.effectiveRuntimeRealization.interfaces."overlay-east-west";
  in
    if overlayIface.runtimeIfName == expectedInterface
      && overlayIface.renderedIfName == expectedInterface
      && overlayIface.sourceKind == "overlay"
    then
      true
    else
      throw "provider-overlay-runtime-interface-name failed: CPM must preserve inventory controlPlane.sites.*.overlays.*.runtimeNodes.<node>.service.interface as effectiveRuntimeRealization.interfaces.<overlay>.runtimeIfName/renderedIfName so renderers install routes/firewall rules on the provider-created TUN name instead of the logical overlay key."
' >/dev/null

echo "PASS provider-overlay-runtime-interface-name"
