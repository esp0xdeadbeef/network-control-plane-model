#!/usr/bin/env bash
# GAMP-ID: FS-390-HDS-010-SDS-010-SMS-010
# Construction regression: CPM preserves the upstream NFM forwarding artifact for renderers.
set -euo pipefail

trace_id="FS-390-HDS-010-SDS-010-SMS-010"
repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
network_labs_root="${NETWORK_LABS_ROOT:-${repo_root}/../network-labs}"
network_forwarding_model_root="${NETWORK_FORWARDING_MODEL_ROOT:-${repo_root}/../network-forwarding-model}"
tmp_dir="$(mktemp -d "/tmp/${trace_id}-cpm-artifact.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
  echo "FAIL ${trace_id}: $*" >&2
  exit 1
}

[[ -d "${network_labs_root}" ]] || fail "missing network-labs root: ${network_labs_root}"
[[ -d "${network_forwarding_model_root}" ]] || fail "missing network-forwarding-model root: ${network_forwarding_model_root}"
command -v jq >/dev/null 2>&1 || fail "jq is required"

ln -s "${network_labs_root}/GAMP" "${tmp_dir}/GAMP"
NETWORK_LABS_CURRENT_LAB_DIR="${tmp_dir}/current-lab" \
NETWORK_FORWARDING_MODEL_ROOT="${network_forwarding_model_root}" \
  bash "${network_labs_root}/scripts/select-current-lab.sh" SMT "${trace_id}" >/dev/null

forwarding_from_cpm="${tmp_dir}/forwarding-from-cpm.json"

REPO_ROOT="${repo_root}" \
INTENT_PATH="${tmp_dir}/current-lab/intent-s-router-nixos.nix" \
INVENTORY_PATH="${tmp_dir}/current-lab/inventory-s-router-nixos.nix" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure \
    --json \
    --expr '
      let
        flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
        out = flake.libBySystem.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
          validateForwardingModel = false;
          validateRuntimeModel = false;
        };
      in
        out.forwardingOut
    ' >"${forwarding_from_cpm}" || fail "CPM compileAndBuildFromPaths did not expose forwardingOut"

jq -e --arg trace "${trace_id}" '
  .enterprise."mini-smt".site[$trace].publicIpv4DestinationPolicy.destinationClasses as $classes
  | $classes["public-ipv4-destination::198.51.100.10"] as $enterpriseClient
  | $classes["public-ipv4-destination::198.51.100.11"] as $tenantService
  | $classes["public-ipv4-destination::203.0.113.50"] as $seededTenantService
  | $classes["public-ipv4-destination::198.51.100.12"] as $localOwned
  | $classes["public-ipv4-destination::198.51.100.13"] as $providerOwned
  | $classes["public-ipv4-destination::198.51.100.14"] as $publicIngress
  | ($enterpriseClient.destinationClass == "enterprise-client")
    and ($enterpriseClient.ownerKind == "tenant")
    and ($enterpriseClient.ownerName == "client")
    and ($enterpriseClient.source == "ownership.prefixes")
    and ($tenantService.destinationClass == "tenant-service")
    and ($tenantService.ownerName == "tenant-api")
    and ($seededTenantService.destinationClass == "tenant-service")
    and ($seededTenantService.ownerName == "fixture-missing-output")
    and ($localOwned.destinationClass == "locally-owned-routed")
    and ($localOwned.ownerName == "locally-routed-endpoint")
    and ($providerOwned.destinationClass == "provider-owned")
    and ($providerOwned.ownerName == "provider-owned-endpoint")
    and ($publicIngress.destinationClass == "public-ingress")
    and ($publicIngress.ownerName == "public-web")
    and ([
      $enterpriseClient,
      $tenantService,
      $seededTenantService,
      $localOwned,
      $providerOwned,
      $publicIngress
    ] | all(.modelOwned == true and (.ownerName != null) and (.ownerKind != null) and (.source != null)))
' "${forwarding_from_cpm}" >/dev/null || {
  jq '.enterprise."mini-smt".site[$trace].publicIpv4DestinationPolicy' \
    --arg trace "${trace_id}" \
    "${forwarding_from_cpm}" >&2
  fail "CPM forwardingOut lost FS-390 public IPv4 destination classification"
}

echo "PASS ${trace_id}: CPM exposes NFM forwarding artifact for renderer audit output"
