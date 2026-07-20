#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-030-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

assert_protected_records() {
  local name="$1"
  local output="$2"
  local expected_site="$3"
  local expected_host="$4"
  local expected_consumer="$5"

  jq -e \
    --arg expected_site "${expected_site}" \
    --arg expected_host "${expected_host}" \
    --arg expected_consumer "${expected_consumer}" '
    def has_id($id): (.gampIds // [] | index($id)) != null;
    def pppoe_credentials:
      [
        .control_plane_model.data
        | to_entries[].value
        | to_entries[].value.runtimeTargets
        | to_entries[].value.services.pppoe?
        | select(. != null)
        | if .client? then .client.credentials
          elif .server? then .server.credentials
          else empty
          end
      ];
    .control_plane_model as $cpm
    | ($cpm.secretDeclarations // []) as $declarations
    | ($cpm.secretSources // []) as $sources
    | ($cpm.sourceBindings // []) as $bindings
    | ($cpm.secretDeliveryRecords // []) as $deliveries
    | ($cpm.secretReadiness // {}) as $readiness
    | ($declarations | length) == 2
      and ($sources | length) == 2
      and ($bindings | length) == 2
      and all($declarations[];
        .site == $expected_site
        and .host == $expected_host
        and .consumer.node == $expected_consumer
        and .credentialClass == "provider-credential"
        and .required == true
        and .requiredness == "mandatory"
        and .material == "reference-only"
        and .plaintextMaterial == false
        and .sourceSelected == false
        and has_id("FS-800-HDS-020-SDS-020")
        and has_id("FS-800-HDS-010-SDS-030-SMS-020")
      )
      and any($declarations[]; .purpose == "pppoe-username")
      and any($declarations[]; .purpose == "pppoe-password")
      and all($sources[];
        .sourceClass == "deployment-platform-secret-reference"
        and (.reference.runtimePath | test("^hat-pppoe-(username|password)$"))
        and (.reference.mediatedRuntimePath | startswith("/run/secrets/hat-pppoe-"))
        and .materialAccess == "not-supplied-by-source-record"
        and .plaintextMaterial == false
        and .providerNeutral == true
        and .fixedSecretManagerRequired == false
        and has_id("FS-800-HDS-020-SDS-020")
        and has_id("FS-800-HDS-010-SDS-030-SMS-020")
      )
      and all($bindings[];
        .bindingKind == "declaration-source"
        and .sourceClass == "deployment-platform-secret-reference"
        and (.sourceFieldPath | startswith("deployment.hosts." + $expected_host + ".hat.providerAccess.residentialPppoeHostTestnet.credentials."))
        and .policyAuthority.createsRouteAuthority == false
        and .policyAuthority.createsFirewallPolicy == false
        and .policyAuthority.createsDnsPolicy == false
        and .policyAuthority.createsPublicIngress == false
        and .policyAuthority.createsTenantReachability == false
        and .policyAuthority.createsTrustBoundary == false
        and .policyAuthority.createsNetworkBehavior == false
        and has_id("FS-800-HDS-020-SDS-020")
        and has_id("FS-800-HDS-010-SDS-030-SMS-020")
      )
      and (pppoe_credentials | length) > 0
      and all(pppoe_credentials[];
        .labOnly == true
        and (has("username") | not)
        and (has("password") | not)
        and .usernameFile == "/run/secrets/hat-pppoe-username"
        and .passwordFile == "/run/secrets/hat-pppoe-password"
      )
      # FS-840-HDS-010-SDS-010-SMS-010: delivery records scoped by consumer
      and ($deliveries | length) == 2
      and all($deliveries[];
        .deliveryScope.site == $expected_site
        and .deliveryScope.host == $expected_host
        and .deliveryScope.consumer.node == $expected_consumer
        and (.mediatedPath | startswith("/run/secrets/hat-pppoe-"))
        and has_id("FS-840-HDS-010-SDS-010-SMS-010")
      )
      # FS-840-HDS-010-SDS-010-SMS-030: readiness diagnostics
      and ($readiness.allMaterialReady == false)
      and (($readiness.readinessDiagnostics // []) | length) == 2
      and all(($readiness.readinessDiagnostics // [])[];
        .materialAccess == "not-supplied-by-source-record"
        and (.mediatedPath | startswith("/run/secrets/hat-pppoe-"))
        and (.diagnostic | startswith("FS-840-HDS-010-SDS-010-SMS-030"))
        and has_id("FS-840-HDS-010-SDS-010-SMS-030")
      )
  ' "${output}" >/dev/null || {
    echo "FAIL hat-protected-secret-records-contract: ${name} protected records not preserved" >&2
    exit 1
  }
}

nixos_output="${tmp_dir}/hat-nixos.json"
clab_output="${tmp_dir}/hat-clab.json"

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

assert_protected_records \
  "nixos" \
  "${nixos_output}" \
  "nixos" \
  "s-router-nixos" \
  "esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"

assert_protected_records \
  "clab" \
  "${clab_output}" \
  "clab" \
  "s-router-clab" \
  "esp0xdeadbeef-site-b-clab-core-testnet-host-isp"

echo "PASS hat-protected-secret-records-contract"
