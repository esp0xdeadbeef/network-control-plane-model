#!/usr/bin/env bash
# GAMP-ID: FS-430-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-430-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-430-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

output_json="$(mktemp)"
trap 'rm -f "${output_json}"' EXIT

cd "${repo_root}"

nix eval \
  --extra-experimental-features 'nix-command flakes' \
  --impure --json --expr '
    let
      flake = builtins.getFlake ("path:" + toString ./.);
      system = builtins.currentSystem;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      lib = pkgs.lib;
      helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
      buildNatIntent = import ./src/cpm/firewall-intent/nat.nix { inherit helpers; };
      siteAttrs = {
        domains.tenants = [
          {
            name = "tenant-a";
            ipv6 = "fd42:dead:beef:10::/64";
          }
        ];
      };
      baseWan = {
        sourceKind = "wan";
        upstream = "wan";
        sourceInterfaceName = "wan0";
        runtimeIfName = "eth0";
        hostUplink = {
          ipv4 = { method = "dhcp"; };
          ipv6 = {
            method = "slaac";
          };
        };
        wan.egress.ipv6.translation = {
          mode = "nat66";
          translatedPrefix = "2001:db8:430::/64";
        };
      };
      alternateWan = {
        sourceKind = "wan";
        upstream = "backup-wan";
        sourceInterfaceName = "backup0";
        runtimeIfName = "eth9";
        hostUplink.ipv6 = {
          method = "slaac";
          egressAuthority = true;
        };
        wan.egress.ipv6.translation = {
          mode = "nat66";
          translatedPrefix = "2001:db8:999::/64";
        };
      };
      transitInterface = {
        sourceKind = "p2p";
        runtimeIfName = "tenant-transit0";
      };
      selectedNat66Target = {
        role = "core";
        egressIntent = {
          exit = true;
          trafficClass = "tenant-internet";
          uplinks = [ "wan" ];
          wanInterfaces = [ "wan" ];
          nat66.wan = {
            mode = "nat66";
            sourcePrefixes = [ "fd42:dead:beef:10::/64" ];
          };
        };
      };
      noSourceScopeTarget = {
        role = "core";
        egressIntent = selectedNat66Target.egressIntent // {
          nat66.wan = {
            mode = "nat66";
            sourcePrefixes = [ ];
          };
        };
      };
      noWanTranslation = baseWan // {
        wan.egress.ipv6.translation = { };
      };
      natFor = target: interfaces: runtimeOriginSourcePrefixes:
        buildNatIntent {
          inherit siteAttrs target runtimeOriginSourcePrefixes;
          overlayNames = [ ];
          interfaceRecords = interfaces;
        };
      unavailableEgress = natFor selectedNat66Target [ baseWan alternateWan transitInterface ] [ ];
      missingTranslation = natFor selectedNat66Target [ noWanTranslation alternateWan transitInterface ] [ ];
      missingSourceScope = natFor noSourceScopeTarget [ baseWan alternateWan transitInterface ] [ ];
      unavailableDiagnostic = builtins.head unavailableEgress.diagnostics.nat66;
      missingTranslationDiagnostic = builtins.head missingTranslation.diagnostics.nat66;
      missingSourceDiagnostic = builtins.head missingSourceScope.diagnostics.nat66;
      commonDiagnosticComplete = diagnostic:
        diagnostic.sourceScope == [ "fd42:dead:beef:10::/64" ]
        && diagnostic.trafficClass == "tenant-internet"
        && diagnostic.egressSurface.selectedUplinks == [ "wan" ]
        && diagnostic.egressSurface.selectedUplinkInterfaces == [ "eth0" ]
        && diagnostic.translatedAddressOrPrefix == [ "2001:db8:430::/64" ]
        && diagnostic.addressFamily == 6
        && diagnostic.tenantIsolationBoundary == {
          kind = "tenant-source-prefix";
          tenants = [ "tenant-a" ];
          sourcePrefixes = [ "fd42:dead:beef:10::/64" ];
        }
        && diagnostic.failClosed == true
        && diagnostic.mode == "fail-closed"
        && diagnostic.fallback == {
          unmodeledEgress = false;
          untranslatedUlaRoute = false;
          alternateProviders = false;
        };
    in {
      checks = {
        unavailableEgressDiagnosticComplete = commonDiagnosticComplete unavailableDiagnostic;
        unavailableEgressFailsClosed =
          unavailableEgress.families.ipv6 == false
          && unavailableEgress.masqueradeSourcePrefixes6 == [ ]
          && unavailableEgress.masqueradeInterfaces6 == [ ]
          && unavailableEgress.routeSafety.coreOriginUplinkDefault.blackholed == true
          && unavailableEgress.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false
          && !(builtins.elem "eth9" unavailableEgress.masqueradeInterfaces6);
        missingTranslationNamesUnavailablePrefix =
          missingTranslationDiagnostic.translatedAddressOrPrefix == [ ]
          && missingTranslationDiagnostic.translatedAddressOrPrefixState == "unavailable"
          && missingTranslationDiagnostic.egressSurface.selectedUplinkInterfaces == [ "eth0" ];
        missingTranslationFailsClosedWithoutAlternate =
          missingTranslation.families.ipv6 == false
          && missingTranslation.masqueradeSourcePrefixes6 == [ ]
          && missingTranslation.masqueradeInterfaces6 == [ ]
          && !(builtins.elem "eth9" missingTranslation.masqueradeInterfaces6);
        missingSourceScopeDiagnosticNamesBoundary =
          missingSourceDiagnostic.sourceScope == [ ]
          && missingSourceDiagnostic.trafficClass == "tenant-internet"
          && missingSourceDiagnostic.egressSurface.selectedUplinks == [ "wan" ]
          && missingSourceDiagnostic.translatedAddressOrPrefix == [ "2001:db8:430::/64" ]
          && missingSourceDiagnostic.tenantIsolationBoundary == {
            kind = "tenant-source-prefix";
            tenants = [ "tenant-a" ];
            sourcePrefixes = [ ];
          };
        missingSourceScopeFailsClosed =
          missingSourceScope.families.ipv6 == false
          && missingSourceScope.masqueradeSourcePrefixes6 == [ ]
          && missingSourceScope.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false;
        # SMS-020 SN1: diagnostic always has complete fields (sourceScope, trafficClass,
        # egressSurface, translatedAddressOrPrefix, addressFamily, tenantIsolationBoundary)
        sn1_diagnosticFieldsComplete =
          let
            allDiagnostics = unavailableEgress.diagnostics.nat66
              ++ missingTranslation.diagnostics.nat66
              ++ missingSourceScope.diagnostics.nat66;
            fieldCompleteness = map (d:
              d ? sourceScope
              && d ? trafficClass
              && d ? egressSurface
              && d ? translatedAddressOrPrefix
              && d ? addressFamily
              && d ? tenantIsolationBoundary
              && d ? failClosed
              && d ? mode
              && d ? fallback
            ) allDiagnostics;
          in builtins.all (x: x) fieldCompleteness;
        # SMS-020 SN2: no duplicate sourcePrefix with different translatedPrefix
        sn2_noAmbiguousRecords =
          let
            records = unavailableEgress.translationRecords
              ++ missingTranslation.translationRecords
              ++ missingSourceScope.translationRecords;
            grouped = builtins.groupBy (r: builtins.concatStringsSep "," r.sourceScope) records;
            ambiguous = builtins.filter
              (group:
                let
                  prefixes = builtins.map (r: builtins.concatStringsSep "," r.translatedAddressOrPrefix) group;
                in builtins.length (lib.lists.unique prefixes) > 1
              )
              (builtins.attrValues grouped);
          in ambiguous == [ ];
      };
      context = {
        inherit unavailableEgress missingTranslation missingSourceScope;
      };
    }
  ' >"${output_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${output_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL translation-failure-diagnostics-fail-closed" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  echo "resolved context:" >&2
  jq '.context' "${output_json}" >&2
  exit 1
fi

echo "PASS translation-failure-diagnostics-fail-closed"
