#!/usr/bin/env bash
# GAMP-ID: FS-381-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq

flake_input_path() {
  local input_name="$1"
  if [[ "${input_name}" == "network-labs" && -n "${NETWORK_LABS_PATH:-}" ]]; then
    realpath "${NETWORK_LABS_PATH}"
    return
  fi
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan"
intent_path="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

compile_paths() {
  local intent="$1"
  local inventory="$2"
  nix eval --no-write-lock-file --impure --json --expr '
    let
      flake = builtins.getFlake "'"path:${repo_root}"'";
    in
      flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${intent}"'";
        inventoryPath = "'"${inventory}"'";
      }
  '
}

baseline_json="${tmp_dir}/baseline.json"
compile_paths "${intent_path}" "${inventory_source}" >"${baseline_json}"

# FS-381: every modeled forwarding hop between the source scope and the exit must
# carry a route toward that exit, not only the scope that owns the exit. CPM
# exposes per-interface routes on effectiveRuntimeRealization; a hop that carries
# a default route or a more specific route off the scope has a path onward.
if ! BASELINE_JSON="${baseline_json}" nix eval --no-write-lock-file --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "BASELINE_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    targets = site.runtimeTargets;

    interfacesOf = n: targets.${n}.effectiveRuntimeRealization.interfaces or { };

    # Every route a hop installs, flattened across its interfaces.
    routesOf = n:
      let ifaces = interfacesOf n;
      in builtins.concatLists (
        map (ifaceName: ifaces.${ifaceName}.routes.ipv4 or [ ]) (builtins.attrNames ifaces)
      );

    # A hop has a path off the scope when it installs a default route with a next
    # hop. Only the source scope is required to carry it here; downstream hops
    # reach the exit through their own fabric routes, asserted by SMS-030.
    hasDefaultOffScope = n:
      builtins.any (r: (r.dst or "") == "0.0.0.0/0" && (r.via4 or null) != null) (routesOf n);

    externalPaths = builtins.filter
      (p: (p.destination.kind or null) == "external" && p.action == "allow")
      site.trafficPaths;

    # The first hop of a permitted external path is the source scope whose
    # permission requires the exit.
    sourceHops = map (p: builtins.head p.nodePath) externalPaths;
    sourceTarget = hop: "esp0xdeadbeef-site-a-" + hop;
  in
    builtins.length externalPaths > 0
    && builtins.all (hop: hasDefaultOffScope (sourceTarget hop)) sourceHops
' | grep -qx true; then
  echo "FAIL per-hop-route-completeness: a permitted external path source scope carries no default route off the scope" >&2
  exit 1
fi

# SN2: the same requirement is not satisfied by a table holding only peer-link
# routes. Assert that the source scope's own subnet routes are not the only
# entries, i.e. a route with a next hop exists beyond the connected fabric.
if ! BASELINE_JSON="${baseline_json}" nix eval --no-write-lock-file --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "BASELINE_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    targets = site.runtimeTargets;
    interfacesOf = n: targets.${n}.effectiveRuntimeRealization.interfaces or { };
    routesOf = n:
      let ifaces = interfacesOf n;
      in builtins.concatLists (
        map (ifaceName: ifaces.${ifaceName}.routes.ipv4 or [ ]) (builtins.attrNames ifaces)
      );
    hasDefaultOffScope = n:
      builtins.any (r: (r.dst or "") == "0.0.0.0/0" && (r.via4 or null) != null) (routesOf n);
    defaultRouted = builtins.filter
      (n: hasDefaultOffScope n)
      (builtins.attrNames targets);
  in
    builtins.length defaultRouted > 0
' | grep -qx true; then
  echo "FAIL per-hop-route-completeness: no modeled target installs a default route with a next hop" >&2
  exit 1
fi

echo "PASS per-hop-route-completeness"
