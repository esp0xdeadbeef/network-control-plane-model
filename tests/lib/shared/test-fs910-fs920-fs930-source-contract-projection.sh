#!/usr/bin/env bash
# GAMP-ID: FS-910-HDS-010-SDS-010
# GAMP-ID: FS-920-HDS-010-SDS-011
# GAMP-ID: FS-920-HDS-010-SDS-012
# GAMP-ID: FS-920-HDS-010-SDS-013
# GAMP-ID: FS-930-HDS-010-SDS-011
# GAMP-ID: FS-930-HDS-010-SDS-012
# GAMP-ID: FS-930-HDS-010-SDS-013
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
archive_json="${tmp_dir}/flake-archive.json"
trap 'rm -rf "${tmp_dir}"' EXIT

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_path="$(
  jq -er '.inputs["network-labs"].path' "${archive_json}"
)"

if [[ -f "${labs_path}/GAMP/HAT/emulated-isp-residential-testnet/intent.nix" ]]; then
  source_dir="${labs_path}/GAMP/HAT/emulated-isp-residential-testnet"
  inventory_paths=(
    "${source_dir}/inventory-nixos.nix"
    "${source_dir}/inventory-clab.nix"
    "${source_dir}/inventory-hetz.nix"
  )
elif [[ -f "${labs_path}/GAMP/SAT/intent.nix" ]]; then
  source_dir="${labs_path}/GAMP/SAT"
  inventory_paths=("${source_dir}/inventory.nix")
else
  echo "FAIL fs910-fs920-fs930-source-contract-projection: missing controlled GAMP/HAT or GAMP/SAT lab source under ${labs_path}" >&2
  exit 1
fi

intent_path="${source_dir}/intent.nix"

for inventory_path in "${inventory_paths[@]}"; do
  profile_name="$(basename "${inventory_path}" .nix)"
  source_json="${tmp_dir}/${profile_name}-source-contracts.json"
  cpm_json="${tmp_dir}/${profile_name}-cpm.json"

  nix eval --impure --json --expr "
    let
      inventory = import ${inventory_path};
    in
    {
      operationalPrivacyContracts = inventory.operationalPrivacyContracts;
      failureHandlingContracts = inventory.failureHandlingContracts;
      failureDiagnosticContracts = inventory.failureDiagnosticContracts;
    }
  " >"${source_json}"

  nix run \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory_path}" \
    "${cpm_json}" >/dev/null

  jq -e \
    --slurpfile source "${source_json}" '
    def has_all($expected; $actual):
      all($expected[]; . as $expected_value | $actual | index($expected_value) != null);
    def renderer_contracts:
      [
        .control_plane_model.data
        | to_entries[].value
        | to_entries[].value.rendererContracts?
        | select(. != null)
      ];
    .control_plane_model as $cpm
    | $source[0] as $src
    | $cpm.operationalPrivacyContracts == $src.operationalPrivacyContracts
      and $cpm.failureHandlingContracts == $src.failureHandlingContracts
      and $cpm.failureDiagnosticContracts == $src.failureDiagnosticContracts
      and $cpm.operationalPrivacyContracts.marker == "SAT-SRC-INVENTORY-OPERATIONAL-PRIVACY"
      and $cpm.operationalPrivacyContracts.defaultHigherDetailEnabled == false
      and $cpm.operationalPrivacyContracts.explicitScopedDetailModeRequired == true
      and has_all([
        "FS-910-HDS-010-SDS-010",
        "FS-910-HDS-010-SDS-010-SMS-010",
        "FS-910-HDS-010-SDS-010-SMS-020",
        "FS-910-HDS-010-SDS-010-SMS-030"
      ]; $cpm.operationalPrivacyContracts.gampIds)
      and $cpm.failureHandlingContracts.marker == "SAT-SRC-INVENTORY-FAILURE-HANDLING"
      and $cpm.failureHandlingContracts.responseAuthority.defaultBehavior == "deny-by-default"
      and $cpm.failureHandlingContracts.responseAuthority.unmodeledFallbackAuthority == false
      and $cpm.failureHandlingContracts.responseAuthority.createsDnsFallback == false
      and $cpm.failureHandlingContracts.responseAuthority.createsRouteFallback == false
      and $cpm.failureHandlingContracts.responseAuthority.createsPublicIngress == false
      and has_all([
        "provider-loss",
        "overlay-loss",
        "dns-failure",
        "route-withdrawal",
        "route-leak",
        "address-conflict",
        "state-loss",
        "ingress-conflict",
        "nat-exhaustion",
        "nat66-exhaustion",
        "secret-expiry"
      ]; [$cpm.failureHandlingContracts.modeledFailureClasses[].failureClass])
      and has_all([
        "FS-920-HDS-010-SDS-011",
        "FS-920-HDS-010-SDS-012",
        "FS-920-HDS-010-SDS-013",
        "FS-920-HDS-010-SDS-010-SMS-010",
        "FS-920-HDS-010-SDS-010-SMS-020",
        "FS-920-HDS-010-SDS-010-SMS-030"
      ]; $cpm.failureHandlingContracts.gampIds)
      and $cpm.failureDiagnosticContracts.marker == "SAT-SRC-INVENTORY-FAILURE-DIAGNOSTICS"
      and has_all([
        "owningLayer",
        "affectedScope",
        "input",
        "reason",
        "sourceLocation"
      ]; $cpm.failureDiagnosticContracts.requiredDiagnosticFields)
      and $cpm.failureDiagnosticContracts.redaction.exposePlaintextSecrets == false
      and $cpm.failureDiagnosticContracts.redaction.exposeFullPayloads == false
      and $cpm.failureDiagnosticContracts.redaction.exposeUnboundedDebug == false
      and $cpm.failureDiagnosticContracts.repairRouting.routeMalformedInputToOwningSourceLayer == true
      and $cpm.failureDiagnosticContracts.repairRouting.lowerLayerHeuristicRepairAllowed == false
      and $cpm.failureDiagnosticContracts.repairRouting.rendererLocalRepairAllowed == false
      and $cpm.failureDiagnosticContracts.repairRouting.scriptLocalRepairAllowed == false
      and has_all([
        "FS-930-HDS-010-SDS-011",
        "FS-930-HDS-010-SDS-012",
        "FS-930-HDS-010-SDS-013",
        "FS-930-HDS-010-SDS-010-SMS-010",
        "FS-930-HDS-010-SDS-010-SMS-020",
        "FS-930-HDS-010-SDS-010-SMS-030"
      ]; $cpm.failureDiagnosticContracts.gampIds)
      and all(renderer_contracts[];
        (has("operationalPrivacyContracts") | not)
        and (has("failureHandlingContracts") | not)
        and (has("failureDiagnosticContracts") | not)
      )
    ' "${cpm_json}" >/dev/null || {
    echo "FAIL fs910-fs920-fs930-source-contract-projection: CPM did not preserve locked source contracts exactly for ${profile_name}" >&2
    exit 1
  }
done

echo "PASS fs910-fs920-fs930-source-contract-projection"
