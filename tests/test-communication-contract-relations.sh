#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

archive_json="$(mktemp)"
trap 'rm -f "'"${archive_json}"'"' EXIT

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
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

intent_path="${labs_path}/examples/s-router-test-three-site/intent.nix"
inventory_path="${labs_path}/examples/s-router-test-three-site/inventory-nixos.nix"

expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  built = flake.lib.${system}.compileAndBuildFromPaths {
    inputPath = builtins.getEnv "TEST_INPUT_PATH";
    inventoryPath = builtins.getEnv "TEST_INVENTORY_PATH";
  };
  site = built.control_plane_model.data.esp0xdeadbeef."site-c";
in
  builtins.any
    (relation: (relation.id or null) == "allow-sitec-home-to-local-services")
    ((site.communicationContract.relations or [ ]) ++ (site.communicationContract.allowedRelations or [ ]))
'

if TEST_INPUT_PATH="$intent_path" TEST_INVENTORY_PATH="$inventory_path" \
  nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS communication-contract-relations"
else
  echo "FAIL communication-contract-relations" >&2
  exit 1
fi
