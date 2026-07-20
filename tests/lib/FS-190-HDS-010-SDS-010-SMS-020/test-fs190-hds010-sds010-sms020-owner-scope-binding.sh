#!/usr/bin/env bash
# GAMP-ID: FS-190-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
# SMS Construction Handoff: Owner-Scope Binding Module
#
# Tests:
#   CH1 — Valid owning tenant/service scope → OwnerScopedExposureRecord
#   CH2 — Missing/null owner scope → diagnostic.missing-owner-scope + no handoff
#   CH3 — Scope inheritance from host placement → exposure-scope-inherited-from-host
#
# Seeded negatives:
#   SN1 — null ownerScope → diagnostic.missing-owner-scope
#   SN2 — host-placement scope inheritance → exposure-scope-inherited-from-host
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

# --- CH1: Valid owning scope → OwnerScopedExposureRecord ---
ch1_json="$(mktemp)"
ch1_stderr="$(mktemp)"
trap 'rm -f "$ch1_json" "$ch1_stderr"' EXIT

eval_ch1_fixture() {
  local output_path="$1"
  local stderr_path="$2"

  REPO_ROOT="$repo_root" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure --json --expr '
        let
          repoRoot = builtins.getEnv "REPO_ROOT";
          localLib = import (repoRoot + "/lib/utils.nix");
          helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
          lib = {
            concatMap = f: list: builtins.concatLists (map f list);
          };
          common = {
            failForwarding = path: message:
              throw "forwarding-model update required: ${path}: ${message}";
          };
          uniqueStrings = values:
            helpers.sortedNames (
              builtins.listToAttrs (
                map
                  (value: { name = value; value = true; })
                  (builtins.filter helpers.isNonEmptyString values)
              )
            );
          services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
            inherit lib helpers common uniqueStrings;
            sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
            policyEndpointBindings = {
              externals.wan = {
                uplinks = [ "wan" ];
                runtimeBindings = [ ];
              };
              services.dmz-nebula = {
                providers = [ "c-router-lighthouse" ];
                trafficType = "nebula";
              };
              relations = [ {
                action = "allow";
                from = {
                  kind = "external";
                  uplinks = [ "wan" ];
                };
                id = "allow-sitec-wan-to-dmz-nebula";
                to = {
                  kind = "service";
                  name = "dmz-nebula";
                };
                trafficType = "nebula";
              } ];
            };
            providerEndpointForServiceProvider = providerName: null;
            providerTenantsForServiceProvider = providerName: [ "dmz" ];
            preferredDnsUplinksForService = serviceName: [ ];
            preferredDnsUplinksByRelationForService = serviceName: { };
          };
          svc = builtins.head services;
        in
        {
          name = svc.name;
          exposureClass = svc.exposureClass;
          exposure = svc.exposure;
        }
      ' > "$output_path" 2> "$stderr_path"
}

eval_ch1_fixture "$ch1_json" "$ch1_stderr"

ch1_ok="$(
  jq -r '
    .name == "dmz-nebula"
    and .exposureClass == "public-ingress"
    and .exposure.classificationSource == "communicationContract.relations"
    and .exposure.owningScope == {"kind":"service","name":"dmz-nebula"}
    and (.exposure.records | length) == 1
    and .exposure.records[0].ownerScope == {"kind":"service","name":"dmz-nebula"}
    and .exposure.records[0].relationId == "allow-sitec-wan-to-dmz-nebula"
    and .exposure.records[0].exposureClass == "public-ingress"
    and .exposure.records[0].requesterScope.kind == "external"
    and .exposure.records[0].requesterScope.selector == "uplinks"
    and .exposure.records[0].sourceKind == "external"
  ' "$ch1_json"
)"
if [[ "$ch1_ok" != "true" ]]; then
  echo "FAIL owner-scope-binding: CH1 — valid owning scope did not produce correctly scoped OwnerScopedExposureRecord" >&2
  jq '.' "$ch1_json" >&2
  exit 1
fi

# --- SN1 / CH2: Null ownerScope → diagnostic.missing-owner-scope ---
sn1_json="$(mktemp)"
sn1_stderr="$(mktemp)"
trap 'rm -f "$ch1_json" "$ch1_stderr" "$sn1_json" "$sn1_stderr"' EXIT

eval_sn1_fixture() {
  local output_path="$1"
  local stderr_path="$2"

  REPO_ROOT="$repo_root" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure --json --expr '
        let
          repoRoot = builtins.getEnv "REPO_ROOT";
          localLib = import (repoRoot + "/lib/utils.nix");
          helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
          lib = {
            concatMap = f: list: builtins.concatLists (map f list);
          };
          common = {
            failForwarding = path: message:
              throw "forwarding-model update required: ${path}: ${message}";
          };
          uniqueStrings = values:
            helpers.sortedNames (
              builtins.listToAttrs (
                map
                  (value: { name = value; value = true; })
                  (builtins.filter helpers.isNonEmptyString values)
              )
            );
          services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
            inherit lib helpers common uniqueStrings;
            sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
            policyEndpointBindings = {
              externals.wan = {
                uplinks = [ "wan" ];
                runtimeBindings = [ ];
              };
              services.dmz-nebula = {
                providers = [ "c-router-lighthouse" ];
                trafficType = "nebula";
                _testNullOwnerScope = true;
              };
              relations = [ {
                action = "allow";
                from = {
                  kind = "external";
                  uplinks = [ "wan" ];
                };
                id = "allow-sitec-wan-to-dmz-nebula";
                to = {
                  kind = "service";
                  name = "dmz-nebula";
                };
                trafficType = "nebula";
              } ];
            };
            providerEndpointForServiceProvider = providerName: null;
            providerTenantsForServiceProvider = providerName: [ "dmz" ];
            preferredDnsUplinksForService = serviceName: [ ];
            preferredDnsUplinksByRelationForService = serviceName: { };
          };
          svc = builtins.head services;
        in
        svc
      ' > "$output_path" 2> "$stderr_path"
}

if eval_sn1_fixture "$sn1_json" "$sn1_stderr"; then
  echo "FAIL owner-scope-binding: SN1 — null ownerScope was accepted but should have been rejected" >&2
  jq '.' "$sn1_json" >&2
  exit 1
fi
if ! grep -Fq "diagnostic.missing-owner-scope" "$sn1_stderr"; then
  echo "FAIL owner-scope-binding: SN1 — diagnostic.missing-owner-scope not emitted for null ownerScope" >&2
  cat "$sn1_stderr" >&2
  exit 1
fi
# Verify the diagnostic mentions the service name
if ! grep -Fq "dmz-nebula" "$sn1_stderr"; then
  echo "FAIL owner-scope-binding: SN1 — diagnostic did not reference service name dmz-nebula" >&2
  cat "$sn1_stderr" >&2
  exit 1
fi

# --- SN2 / CH3: Host-placement scope inheritance rejection ---
sn2_json="$(mktemp)"
sn2_stderr="$(mktemp)"
trap 'rm -f "$ch1_json" "$ch1_stderr" "$sn1_json" "$sn1_stderr" "$sn2_json" "$sn2_stderr"' EXIT

eval_sn2_fixture() {
  local output_path="$1"
  local stderr_path="$2"

  REPO_ROOT="$repo_root" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure --json --expr '
        let
          repoRoot = builtins.getEnv "REPO_ROOT";
          localLib = import (repoRoot + "/lib/utils.nix");
          helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
          lib = {
            concatMap = f: list: builtins.concatLists (map f list);
          };
          common = {
            failForwarding = path: message:
              throw "forwarding-model update required: ${path}: ${message}";
          };
          uniqueStrings = values:
            helpers.sortedNames (
              builtins.listToAttrs (
                map
                  (value: { name = value; value = true; })
                  (builtins.filter helpers.isNonEmptyString values)
              )
            );
          services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
            inherit lib helpers common uniqueStrings;
            sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
            policyEndpointBindings = {
              externals.wan = {
                uplinks = [ "wan" ];
                runtimeBindings = [ ];
              };
              services.dmz-nebula = {
                providers = [ "c-router-lighthouse" ];
                trafficType = "nebula";
                hostPlacementExposure = "core-boundary";
              };
              relations = [ {
                action = "allow";
                from = {
                  kind = "external";
                  uplinks = [ "wan" ];
                };
                id = "allow-sitec-wan-to-dmz-nebula";
                to = {
                  kind = "service";
                  name = "dmz-nebula";
                };
                trafficType = "nebula";
              } ];
            };
            providerEndpointForServiceProvider = providerName: null;
            providerTenantsForServiceProvider = providerName: [ "dmz" ];
            preferredDnsUplinksForService = serviceName: [ ];
            preferredDnsUplinksByRelationForService = serviceName: { };
          };
          svc = builtins.head services;
        in
        svc
      ' > "$output_path" 2> "$stderr_path"
}

if eval_sn2_fixture "$sn2_json" "$sn2_stderr"; then
  if jq -e '.hostPlacementExposure == "core-boundary"' "$sn2_json" >/dev/null 2>&1; then
    echo "FAIL owner-scope-binding: SN2 — host-placement scope inheritance was accepted but should have been rejected" >&2
    jq '.' "$sn2_json" >&2
    exit 1
  fi
fi
if ! grep -Fq "exposure-scope-inherited-from-host" "$sn2_stderr"; then
  echo "FAIL owner-scope-binding: SN2 — exposure-scope-inherited-from-host diagnostic not emitted" >&2
  cat "$sn2_stderr" >&2
  exit 1
fi

echo "PASS owner-scope-binding"
