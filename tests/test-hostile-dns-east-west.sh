#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
intent_path="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/intent.nix"
inventory_path="/home/deadbeef/github/nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/inventory.nix"

[[ -f "${intent_path}" ]] || { echo "missing intent: ${intent_path}" >&2; exit 1; }
[[ -f "${inventory_path}" ]] || { echo "missing inventory: ${inventory_path}" >&2; exit 1; }

output_json="$(mktemp)"
trap 'rm -f "'"${output_json}"'"' RETURN

nix run "${repo_root}#compile-and-build-control-plane-model" -- "${intent_path}" "${inventory_path}" "${output_json}" >/dev/null

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    hostileEw =
      data.control_plane_model.data.espbranch."site-b".runtimeTargets."espbranch-site-b-b-router-policy"
        .effectiveRuntimeRealization.interfaces
        ."p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west".routes;
    hasDst = routes: destination:
      builtins.any (route: (route.dst or null) == destination) (routes.ipv4 or [ ])
      || builtins.any (route: (route.dst or null) == destination) (routes.ipv6 or [ ]);
  in
    hasDst hostileEw "10.20.10.0/24"
    && hasDst hostileEw "fd42:dead:beef:0010:0000:0000:0000:0000/64"
' | grep -qx true

echo "PASS hostile-dns-east-west"
