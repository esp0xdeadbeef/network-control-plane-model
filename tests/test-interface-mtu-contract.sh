#!/usr/bin/env bash
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd perl

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan-uplink-static-egress"
intent_path="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

[[ -f "${intent_path}" ]] || {
  echo "missing intent fixture: ${intent_path}" >&2
  exit 1
}

[[ -f "${inventory_source}" ]] || {
  echo "missing inventory fixture: ${inventory_source}" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cp "${inventory_source}" "${tmp_dir}/inventory.nix"
chmod u+w "${tmp_dir}/inventory.nix"

if ! perl -0pi -e 's/interface = \{ name = "ens4"; addr4 = "192\.0\.2\.2\/24"; \}; uplink = "wan";/interface = { name = "ens4"; addr4 = "192.0.2.2\/24"; mtu = 1492; }; uplink = "wan";/' "${tmp_dir}/inventory.nix"; then
  echo "failed to patch inventory fixture with explicit MTU" >&2
  exit 1
fi
if ! rg -q 'mtu = 1492' "${tmp_dir}/inventory.nix"; then
  echo "failed to patch single-wan-uplink-static-egress inventory-nixos.nix with explicit MTU" >&2
  exit 1
fi

output_json="${tmp_dir}/out.json"
nix eval --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
    out = flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${tmp_dir}/inventory.nix"'";
    };
  in
    out
' > "${output_json}"

if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    core = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-core-wan";
  in
    core.effectiveRuntimeRealization.interfaces.wan.mtu == 1492
' | grep -qx true; then
  echo "FAIL interface-mtu-contract: CPM did not preserve explicit inventory interface.mtu on the runtime interface" >&2
  exit 1
fi

echo "PASS interface-mtu-contract"
