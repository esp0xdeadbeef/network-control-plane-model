#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

output_json="$(mktemp)"
trap 'rm -f "${output_json}"' EXIT

nix_args=()
if [[ -n "${NETWORK_FORWARDING_MODEL_OVERRIDE:-}" ]]; then
  nix_args+=(--override-input network-forwarding-model "${NETWORK_FORWARDING_MODEL_OVERRIDE}")
fi

nix eval "${nix_args[@]}" \
  --extra-experimental-features 'nix-command flakes' \
  --impure --json "path:${repo_root}#lib.x86_64-linux.compileAndBuildFromPaths" \
  --apply 'f:
    let
      flake = builtins.getFlake ("path:" + toString ./.);
      labs = flake.inputs.network-labs.outPath;
    in
      (f {
        inputPath = labs + "/examples/s-router-overlay-dns-lane-policy/intent.nix";
        inventoryPath = labs + "/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix";
      }).control_plane_model.data' >"${output_json}"

jq -e '
  [
    .[][]?.runtimeTargets[]?.natIntent
    | select(. != null)
    | select((.families.ipv6 // false) == true or ((.masqueradeSourcePrefixes6 // []) | length > 0))
  ] | length == 0
' "${output_json}" >/dev/null || {
  echo "FAIL example-no-nat66-synthesis: examples must not synthesize NAT66 without explicit model support" >&2
  exit 1
}

echo "PASS example-no-nat66-synthesis"
