#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

archive_json="$(mktemp)"
output_json="$(mktemp)"
trap 'rm -f "$archive_json" "$output_json"' EXIT

nix flake archive --json "path:${repo_root}" > "$archive_json"

labs_path="$(
  ARCHIVE_JSON="$archive_json" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then
        throw "tests: missing archived network-labs input path"
      else
        labsPath
  '
)"

REPO_ROOT="$repo_root" \
INTENT_PATH="${labs_path}/examples/s-router-public-overlay-service/intent.nix" \
INVENTORY_PATH="${labs_path}/examples/s-router-public-overlay-service/inventory-nixos.nix" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
        out = flake.lib.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
        };
        services = out.control_plane_model.data.esp0xdeadbeef."site-c".services;
        service =
          builtins.head (builtins.filter (item: (item.name or null) == "dmz-nebula") services);
        endpoint = builtins.head service.providerEndpoints;
        checks = {
          publicOverlayServiceHasProviderEndpoint =
            service.providers == [ "c-router-lighthouse" ]
            && endpoint.name == "c-router-lighthouse";
          providerEndpointHasExplicitInventoryIPv4 =
            endpoint.ipv4 == [ "10.90.10.100" ];
          providerEndpointHasExplicitInventoryIPv6 =
            endpoint.ipv6 == [ "fd42:dead:cafe:10::100" ];
        };
      in
      {
        ok = builtins.all (value: value == true) (builtins.attrValues checks);
        failed =
          flake.inputs.nixpkgs.lib.mapAttrsToList
            (name: _value: name)
            (flake.inputs.nixpkgs.lib.filterAttrs (_name: value: value != true) checks);
        inherit checks service;
      }
    ' > "$output_json"

ok="$(jq -r '.ok' "$output_json")"
if [[ "$ok" != "true" ]]; then
  echo "FAIL service-provider-endpoints" >&2
  jq '.' "$output_json" >&2
  exit 1
fi

echo "PASS service-provider-endpoints"
