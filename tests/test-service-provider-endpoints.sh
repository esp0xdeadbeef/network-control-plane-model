#!/usr/bin/env bash
# GAMP-ID: FS-060-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# Tests SMS-010: provider endpoint binding to inventory;
# rejection of missing runtime facts.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

labs_path="/home/deadbeef/github/network-labs"
output_json="$(mktemp)"
bad_inventory="$(mktemp)"
bad_output="$(mktemp)"
trap 'rm -f "$output_json" "$bad_inventory" "$bad_output"' EXIT

# ── Test 1 (Happy): provider with inventory endpoint → providerEndpoints populated ──
REPO_ROOT="$repo_root" \
INTENT_PATH="${labs_path}/examples/single-wan/intent.nix" \
INVENTORY_PATH="${labs_path}/examples/single-wan/inventory-nixos.nix" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        flake = builtins.getFlake (toString (builtins.getEnv "REPO_ROOT"));
        out = flake.lib.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
        };
        services = out.control_plane_model.data.esp0xdeadbeef."site-a".services;
        service =
          builtins.head (builtins.filter (item: (item.name or null) == "site-dns") services);
        endpoint = builtins.head service.providerEndpoints;
        checks = {
          dnsServiceProviderName = service.providers == [ "s-sigma" ];
          endpointBoundToInventory = endpoint.name == "s-sigma";
          ipv4FromInventory = endpoint.ipv4 == [ "10.20.10.10" ];
          ipv6FromInventory = endpoint.ipv6 == [ "fd42:dead:beef:10::10" ];
        };
      in
      {
        ok = builtins.all (value: value == true) (builtins.attrValues checks);
        failed =
          flake.inputs.nixpkgs.lib.mapAttrsToList
            (name: _value: name)
            (flake.inputs.nixpkgs.lib.filterAttrs (_name: value: value != true) checks);
        inherit checks;
      }
    ' > "$output_json"

ok="$(jq -r '.ok' "$output_json")"
if [[ "$ok" != "true" ]]; then
  echo "FAIL: provider endpoints not bound to explicit inventory addresses" >&2
  jq '.' "$output_json" >&2
  exit 1
fi
echo "PASS [1/2]: provider endpoints bind explicit inventory addresses (s-sigma -> 10.20.10.10 / fd42:dead:beef:10::10)"

# ── Test 2 (Negative): missing inventory endpoint → compile rejected ──
cat > "$bad_inventory" <<NIXEOF
let
  base = import ${labs_path}/examples/single-wan/inventory-nixos.nix;
in
base // {
  endpoints = builtins.removeAttrs (base.endpoints or { }) [ "s-sigma" ];
}
NIXEOF

REPO_ROOT="$repo_root" \
INTENT_PATH="${labs_path}/examples/single-wan/intent.nix" \
INVENTORY_PATH="$bad_inventory" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --raw --expr '
      let
        flake = builtins.getFlake (toString (builtins.getEnv "REPO_ROOT"));
        out = flake.lib.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
        };
        services = out.control_plane_model.data.esp0xdeadbeef."site-a".services;
        service = builtins.head (builtins.filter (item: (item.name or null) == "site-dns") services);
        _force = builtins.deepSeq service "OK";
      in _force
    ' > "$bad_output" 2>&1 || true

if grep -q '^OK$' "$bad_output"; then
  echo "FAIL: missing inventory endpoint should have been rejected but compile produced OK" >&2
  exit 1
fi

if ! grep -q "requires explicit inventory.endpoints.s-sigma" "$bad_output"; then
  echo "FAIL: missing-endpoint diagnostic not found in rejection output" >&2
  cat "$bad_output" >&2
  exit 1
fi

echo "PASS [2/2]: missing inventory endpoint rejected with diagnostic naming the absent runtime fact"
echo "PASS service-provider-endpoints"
