#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd python

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

examples_root="$(flake_input_path network-labs)/examples"
example_root="${examples_root}/single-wan-uplink-static-egress"
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
trap 'rm -rf "'"${tmp_dir}"'"' EXIT

cp "${inventory_source}" "${tmp_dir}/inventory.nix"
chmod u+w "${tmp_dir}/inventory.nix"

python - <<'PY' "${tmp_dir}/inventory.nix"
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = 'interface = { name = "ens4"; addr4 = "192.0.2.2/24"; }; uplink = "wan";'
replacement = 'interface = { name = "ens4"; addr4 = "192.0.2.2/24"; routes = { ipv4 = [ { prefix = "198.51.100.0/24"; via = "192.0.2.1"; } ]; ipv6 = [ { prefix = "2001:db8:51::/64"; via = "2001:db8::1"; } ]; }; }; uplink = "wan";'
if needle not in source:
    raise SystemExit("failed to patch single-wan-uplink-static-egress inventory-nixos.nix")
path.write_text(source.replace(needle, replacement, 1))
PY

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

# shellcheck disable=SC2016
OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    core = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-core-wan";
    routes = core.effectiveRuntimeRealization.interfaces.wan.routes;
    hasRoute = family: dst: via:
      builtins.any
        (route:
          (route.dst or null) == dst
          && (
            if family == "ipv4" then
              (route.via4 or null) == via
            else
              (route.via6 or null) == via
          )
          && ((route.intent or { }).kind or null) == "realized-interface-route"
        )
        (routes.${family} or [ ]);
  in
    hasRoute "ipv4" "198.51.100.0/24" "192.0.2.1"
    && hasRoute "ipv6" "2001:db8:51::/64" "2001:db8::1"
' >/dev/null

echo "PASS realized-interface-routes"
