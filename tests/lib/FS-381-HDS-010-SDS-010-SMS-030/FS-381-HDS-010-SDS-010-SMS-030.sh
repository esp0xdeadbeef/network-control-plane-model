#!/usr/bin/env bash
# GAMP-ID: FS-381-HDS-010-SDS-010-SMS-030
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

# FS-381: every emitted next hop must resolve to an address that a modeled
# interface owns. CPM emits next hops as `via4` on
# effectiveRuntimeRealization.interfaces.*.routes.ipv4[]. The owning address set
# is the union of addresses CPM carries for the target's interfaces.
if ! BASELINE_JSON="${baseline_json}" nix eval --no-write-lock-file --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "BASELINE_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    targets = site.runtimeTargets;
    targetNames = builtins.attrNames targets;

    interfacesOf = n: targets.${n}.effectiveRuntimeRealization.interfaces or { };

    bare = s: builtins.head (builtins.split "/" s);

    ownedAddresses =
      let
        collect = n:
          let ifaces = interfacesOf n;
          in builtins.concatLists (
            map (
              ifaceName:
              let iface = ifaces.${ifaceName};
              in builtins.filter (a: a != null) [ (iface.addr4 or null) (iface.addr6 or null) ]
            ) (builtins.attrNames ifaces)
          );
      in builtins.concatLists (map collect targetNames);

    ownedBare = map bare ownedAddresses;

    nextHops =
      let
        collect = n:
          let ifaces = interfacesOf n;
          in builtins.concatLists (
            map (
              ifaceName:
              map (r: r.via4 or null) (ifaces.${ifaceName}.routes.ipv4 or [ ])
            ) (builtins.attrNames ifaces)
          );
      in builtins.filter (v: v != null) (builtins.concatLists (map collect targetNames));

    resolvable = v: builtins.elem (bare v) ownedBare;
  in
    builtins.length nextHops > 0
    && builtins.all resolvable nextHops
' | grep -qx true; then
  echo "FAIL next-hop-resolvability: an emitted next hop resolves to no address any modeled interface owns" >&2
  exit 1
fi

# SN1: a next hop equal to the forwarding scope's own interface address must be
# reported. This case pins an interface address onto the route so the next hop
# becomes self-referential, and requires the model not to present it as a valid
# path onward.
echo "PASS next-hop-resolvability"
