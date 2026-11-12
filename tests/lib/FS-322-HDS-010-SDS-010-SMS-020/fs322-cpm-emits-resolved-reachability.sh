#!/usr/bin/env bash
# GAMP-ID: FS-322-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-322-HDS-010-SDS-010-SMS-020.md  (Scope Selection Resolution)
# SPEC:   GAMP/SDS/FS-322-HDS-010-SDS-010.md          (Scope Reachability: Offers, Selects, Overlap Precedence)
# OWNER:  network-control-plane-model
#
# EXPECTED TO FAIL. This case records a missing upstream fact, not a renderer bug.
#
# FS-322 SDS assigns reachability derivation to the model chain, and its Software
# Architecture section states it plainly:
#
#   "the compiler computes reachability from scope offers/selects, and
#    permission relations name only what is allowed."
#
# FS-322-HDS-010-SDS-010-SMS-020 lists as an Emitted Interface:
#
#   "Per-scope resolved reachability (ordered selected scopes and their member
#    ...)"
#
# URS is explicit that this is derived, not sourced, and that the two facts must
# not be mixed:
#
#   "reachability ... and permission ... shall not be conflated";
#   "A fact that follows deterministically from other modeled facts shall be
#    derived by the owning layer and shall not be required as source input."
#
# Measured today on the single-wan example, every runtime target exposes
#
#   effectiveRuntimeRealization = [ "interfaces" "loopback"
#                                   "targetOriginatedSelection" ]
#
# with no resolved reachability anywhere, while the same targets do carry
# `forwardingIntent` and `egressIntent` at top level. Downstream renderers
# therefore have no canonical source for what a scope selects.
#
# This was found from the renderer side. network-renderer-nixos has a case
# (tests/test-policy-service-ingress-routes.sh, FS-270) needing a peer access
# unit's return leg in a policy table. Teaching the renderer to mine permission
# relations for it was implemented, measured, and reverted: it conflates
# reachability with permission, which the URS forbids, and it regressed an FS-540
# assertion that a policy table must not reach an unselected tenant.
#
# network-realization-model is NOT at fault and cannot fix this: it asserts
# `candidate.network.data == cpm` and fails with NR_REALIZATION_INVENTED_SEMANTIC
# otherwise, so it may only carry CPM's data verbatim. The fact has to exist here.
#
# Do not make this pass by defaulting, by inferring precedence from member order
# or route enumeration, or by requiring the source to restate the resolution.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

command -v jq >/dev/null 2>&1 || { echo "missing required command: jq" >&2; exit 1; }

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
inventory_path="${example_root}/inventory-nixos.nix"

result_json="$(mktemp)"
trap 'rm -f "${result_json}"' EXIT

REPO_ROOT="${repo_root}" INTENT_PATH="${intent_path}" INVENTORY_PATH="${inventory_path}" \
  nix eval --no-write-lock-file --impure --json --expr '
    let
      repoRoot = builtins.getEnv "REPO_ROOT";
      flake = builtins.getFlake ("path:" + repoRoot);
      system = builtins.currentSystem;
      cpm = flake.libBySystem.${system}.compileAndBuildFromPaths {
        inputPath = builtins.getEnv "INTENT_PATH";
        inventoryPath = builtins.getEnv "INVENTORY_PATH";
        validateForwardingModel = false;
        validateRuntimeModel = false;
      };
      targetsFor = data:
        builtins.concatMap
          (enterprise:
            builtins.concatMap
              (site: builtins.attrValues (site.runtimeTargets or { }))
              (builtins.filter builtins.isAttrs (builtins.attrValues enterprise)))
          (builtins.filter builtins.isAttrs (builtins.attrValues data));
      targets = targetsFor cpm.control_plane_model.data;
      runtimeKeys = map (t: builtins.attrNames t.effectiveRuntimeRealization) targets;
      hasReachability = t:
        (t.effectiveRuntimeRealization or { }) ? resolvedReachability
        || (t.effectiveRuntimeRealization or { }) ? reachability;
      withReachability = builtins.filter hasReachability targets;
    in
    {
      targetCount = builtins.length targets;
      depth = map (t: builtins.attrNames t) targets;
      runtimeKeys = runtimeKeys;
      reachabilityCount = builtins.length withReachability;
    }
  ' >"${result_json}"

target_count="$(jq -r '.targetCount' "${result_json}")"
reachability_count="$(jq -r '.reachabilityCount' "${result_json}")"

if [[ "${target_count}" == "0" ]]; then
  echo "FAIL FS-322-HDS-010-SDS-010-SMS-020: no runtime targets found; the case cannot run" >&2
  exit 1
fi

if [[ "${reachability_count}" == "0" ]]; then
  echo "FAIL FS-322-HDS-010-SDS-010-SMS-020 P1: no runtime target carries resolved" >&2
  echo "  reachability (${target_count} targets inspected)." >&2
  echo "  FS-322-HDS-010-SDS-010-SMS-020 requires per-scope resolved reachability as" >&2
  echo "  an emitted interface: the ordered selected scopes and the prefixes of the" >&2
  echo "  member uplinks each selection resolves to." >&2
  echo "  Present effectiveRuntimeRealization keys: $(jq -c '.depth | .[0]' "${result_json}")" >&2
  echo "  network-realization-model cannot add this: it fails with" >&2
  echo "  NR_REALIZATION_INVENTED_SEMANTIC unless its network data equals CPM verbatim." >&2
  echo "FAIL fs322-cpm-emits-resolved-reachability"
  exit 1
fi

echo "PASS fs322-cpm-emits-resolved-reachability"
