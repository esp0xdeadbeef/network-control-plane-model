#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

output_json="$(mktemp)"
trap 'rm -f "${output_json}"' EXIT

labs_path="$(
  nix flake archive --json "path:${repo_root}" \
    | jq -er '.inputs["network-labs"].path'
)"

REPO_ROOT="${repo_root}" \
LABS_PATH="${labs_path}" \
nix eval \
  --extra-experimental-features 'nix-command flakes' \
  --impure --json --expr '
    let
      flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
      out = flake.lib.x86_64-linux.compileAndBuildFromPaths {
        inputPath = (builtins.getEnv "LABS_PATH") + "/examples/single-wan/intent.nix";
        inventoryPath = (builtins.getEnv "LABS_PATH") + "/examples/single-wan/inventory-clab.nix";
      };
      site = out.control_plane_model.data.esp0xdeadbeef."site-a";
      core = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-core-wan";
      nat = core.natIntent;
    in {
      checks = {
        coreNatEnabled = nat.enabled == true;
        coreNatEnablesIpv4 = nat.families.ipv4 == true;
        coreNatDoesNotInventIpv6 = nat.families.ipv6 == false;
        coreNatMasqueradesWan4 = nat.masqueradeInterfaces4 == [ "ens4" ];
        coreNatDoesNotMasqueradeWan6 = nat.masqueradeInterfaces6 == [ ];
        coreNatHasNoIpv6SourcePrefixes = nat.masqueradeSourcePrefixes6 == [ ];
      };
      context = {
        node = core.logicalNode;
        natIntent = nat;
      };
    }
  ' >"${output_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${output_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL core-ipv6-nat-intent" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  echo "resolved context:" >&2
  jq '.context' "${output_json}" >&2
  exit 1
fi

echo "PASS core-ipv6-nat-intent"
