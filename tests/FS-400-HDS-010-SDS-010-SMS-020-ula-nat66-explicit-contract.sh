#!/usr/bin/env bash
# GAMP-ID: FS-410-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
      baseWan = {
        sourceKind = "wan";
        upstream = "wan";
        sourceInterfaceName = "wan0";
        runtimeIfName = "eth0";
        hostUplink = {
          ipv4 = { method = "dhcp"; };
          ipv6 = {
            method = "slaac";
            egressAuthority = true;
          };
        };
      };
      nat66Wan = baseWan // {
        wan.egress.ipv6.translation.mode = "nat66";
      };
      noAuthorityWan = nat66Wan // {
        hostUplink.ipv6 = {
          method = "slaac";
        };
      };
      transitInterface = {
        sourceKind = "p2p";
        runtimeIfName = "transit0";
      };
      runtimeOriginPrefixes = [
        { family = 4; prefix = "10.19.0.8/32"; }
        { family = 6; prefix = "fd42:dead:beef:1900::8/128"; }
      ];
      nat66Target = {
        role = "core";
        egressIntent = {
          exit = true;
          uplinks = [ "wan" ];
          wanInterfaces = [ "wan" ];
          nat66.wan = {
            mode = "nat66";
            sourcePrefixes = [ "fd42:dead:beef:10::/64" ];
            warning = "lab-nat66-required";
          };
        };
      };
      noIntentTarget = {
        role = "core";
        egressIntent = {
          exit = true;
          uplinks = [ "wan" ];
          wanInterfaces = [ "wan" ];
        };
      };
      noSourceTarget = {
        role = "core";
        egressIntent = {
          exit = true;
          uplinks = [ "wan" ];
          wanInterfaces = [ "wan" ];
          nat66.wan = {
            mode = "nat66";
            sourcePrefixes = [ ];
          };
        };
      };
      natFor = target: interfaces: runtimeOriginSourcePrefixes:
        buildNatIntent {
          siteAttrs = { };
          overlayNames = [ ];
          interfaceRecords = interfaces;
          inherit target runtimeOriginSourcePrefixes;
        };
      nat66 = natFor nat66Target [ nat66Wan transitInterface ] runtimeOriginPrefixes;
      noAuthority = natFor nat66Target [ noAuthorityWan transitInterface ] runtimeOriginPrefixes;
      noWanTranslation = natFor nat66Target [ baseWan transitInterface ] runtimeOriginPrefixes;
      noIntent = natFor noIntentTarget [ nat66Wan transitInterface ] runtimeOriginPrefixes;
      noSource = natFor noSourceTarget [ nat66Wan transitInterface ] [ ];
      noAuthorityDiagnostic = builtins.head noAuthority.diagnostics.nat66;
      noWanTranslationDiagnostic = builtins.head noWanTranslation.diagnostics.nat66;
      noIntentDiagnostic = builtins.head noIntent.diagnostics.nat66;
      noSourceDiagnostic = builtins.head noSource.diagnostics.nat66;
      expectedSourcePrefixes = [
        "fd42:dead:beef:10::/64"
        "fd42:dead:beef:1900::8/128"
      ];
      runtimeOriginOnlySourcePrefixes = [
        "fd42:dead:beef:1900::8/128"
      ];
    in {
      checks = {
        nat66EnabledOnlyWithFullContract = nat66.families.ipv6 == true;
        nat66UsesSelectedBoundary = nat66.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66Boundaries == [ "wan" ];
        nat66TopLevelSourceScope = nat66.masqueradeSourcePrefixes6 == expectedSourcePrefixes;
        nat66RouteSafetySourceScope = nat66.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66SourcePrefixes == expectedSourcePrefixes;
        nat66TopLevelOutputInterface = nat66.masqueradeInterfaces6 == [ "eth0" ];
        nat66RouteSafetyOutputInterface = nat66.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66OutputInterfaces == [ "eth0" ];
        nat66PreservesBlackholedBroadDefault = nat66.routeSafety.coreOriginUplinkDefault.blackholed == true && nat66.routeSafety.coreOriginUplinkDefault.broadCoreOriginUplinkRoutingAllowed == false;
        nat66WarningPreserved = nat66.warnings == [ "lab-nat66-required" ];
        nat66HasNoUnavailableDiagnostic = nat66.diagnostics.nat66 == [ ];
        noEgressAuthorityDisablesNat66 = noAuthority.families.ipv6 == false && noAuthority.masqueradeSourcePrefixes6 == [ ] && noAuthority.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false && noAuthority.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66OutputInterfaces == [ ];
        noEgressAuthorityReportsDiagnostic =
          noAuthorityDiagnostic.code == "nat66-egress-unavailable"
          && noAuthorityDiagnostic.mode == "fail-closed"
          && noAuthorityDiagnostic.failClosed == true
          && noAuthorityDiagnostic.sourceScope == expectedSourcePrefixes
          && noAuthorityDiagnostic.trafficClass == "internet-egress"
          && noAuthorityDiagnostic.egressSurface.selectedUplinks == [ "wan" ]
          && noAuthorityDiagnostic.egressSurface.selectedUplinkInterfaces == [ "eth0" ]
          && noAuthorityDiagnostic.translatedAddressOrPrefix == [ ]
          && noAuthorityDiagnostic.translatedAddressOrPrefixState == "unavailable"
          && noAuthorityDiagnostic.addressFamily == 6
          && noAuthorityDiagnostic.tenantIsolationBoundary.sourcePrefixes == expectedSourcePrefixes
          && noAuthorityDiagnostic.fallback.unmodeledEgress == false
          && noAuthorityDiagnostic.fallback.untranslatedUlaRoute == false
          && noAuthorityDiagnostic.fallback.alternateProviders == false
          && noAuthorityDiagnostic.selectedUplinks == [ "wan" ]
          && noAuthorityDiagnostic.selectedUplinkInterfaces == [ "eth0" ]
          && noAuthorityDiagnostic.nat66TranslationInterfaces == [ "eth0" ]
          && noAuthorityDiagnostic.message == "ULA NAT66 was selected but no selected WAN interface has both NAT66 translation mode and IPv6 egress authority.";
        noWanTranslationDisablesNat66 = noWanTranslation.families.ipv6 == false && noWanTranslation.masqueradeSourcePrefixes6 == [ ] && noWanTranslation.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false && noWanTranslation.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66SourcePrefixes == [ ];
        noWanTranslationReportsDiagnostic =
          noWanTranslationDiagnostic.code == "nat66-egress-unavailable"
          && noWanTranslationDiagnostic.mode == "fail-closed"
          && noWanTranslationDiagnostic.failClosed == true
          && noWanTranslationDiagnostic.sourceScope == expectedSourcePrefixes
          && noWanTranslationDiagnostic.trafficClass == "internet-egress"
          && noWanTranslationDiagnostic.egressSurface.selectedUplinks == [ "wan" ]
          && noWanTranslationDiagnostic.egressSurface.selectedUplinkInterfaces == [ "eth0" ]
          && noWanTranslationDiagnostic.translatedAddressOrPrefix == [ ]
          && noWanTranslationDiagnostic.translatedAddressOrPrefixState == "unavailable"
          && noWanTranslationDiagnostic.addressFamily == 6
          && noWanTranslationDiagnostic.tenantIsolationBoundary.sourcePrefixes == expectedSourcePrefixes
          && noWanTranslationDiagnostic.fallback.unmodeledEgress == false
          && noWanTranslationDiagnostic.fallback.untranslatedUlaRoute == false
          && noWanTranslationDiagnostic.fallback.alternateProviders == false
          && noWanTranslationDiagnostic.selectedUplinks == [ "wan" ]
          && noWanTranslationDiagnostic.selectedUplinkInterfaces == [ "eth0" ]
          && noWanTranslationDiagnostic.message == "ULA NAT66 was selected without any matching WAN NAT66 translation egress space.";
        noNat66IntentDisablesNat66 = noIntent.families.ipv6 == false && noIntent.masqueradeSourcePrefixes6 == [ ] && noIntent.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false && noIntent.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66SourcePrefixes == [ ];
        noNat66IntentReportsExplicitSelectionDiagnostic =
          noIntentDiagnostic.code == "nat66-explicit-selection-required"
          && noIntentDiagnostic.mode == "fail-closed"
          && noIntentDiagnostic.failClosed == true
          && noIntentDiagnostic.sourceScope == runtimeOriginOnlySourcePrefixes
          && noIntentDiagnostic.trafficClass == "internet-egress"
          && noIntentDiagnostic.egressSurface.selectedUplinks == [ "wan" ]
          && noIntentDiagnostic.egressSurface.selectedUplinkInterfaces == [ "eth0" ]
          && noIntentDiagnostic.translatedAddressOrPrefix == [ ]
          && noIntentDiagnostic.translatedAddressOrPrefixState == "unavailable"
          && noIntentDiagnostic.addressFamily == 6
          && noIntentDiagnostic.tenantIsolationBoundary.sourcePrefixes == runtimeOriginOnlySourcePrefixes
          && noIntentDiagnostic.fallback.unmodeledEgress == false
          && noIntentDiagnostic.fallback.untranslatedUlaRoute == false
          && noIntentDiagnostic.fallback.alternateProviders == false
          && noIntentDiagnostic.selectedUplinks == [ "wan" ]
          && noIntentDiagnostic.selectedUplinkInterfaces == [ "eth0" ]
          && noIntentDiagnostic.message == "ULA-to-WAN egress is denied unless NAT66 is explicitly selected.";
        noSourceScopeDisablesNat66 = noSource.families.ipv6 == false && noSource.masqueradeSourcePrefixes6 == [ ] && noSource.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false && noSource.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66SourcePrefixes == [ ];
        noSourceScopeReportsDiagnostic =
          noSourceDiagnostic.code == "nat66-source-prefix-unavailable"
          && noSourceDiagnostic.mode == "fail-closed"
          && noSourceDiagnostic.failClosed == true
          && noSourceDiagnostic.sourceScope == [ ]
          && noSourceDiagnostic.trafficClass == "internet-egress"
          && noSourceDiagnostic.egressSurface.selectedUplinks == [ "wan" ]
          && noSourceDiagnostic.egressSurface.selectedUplinkInterfaces == [ "eth0" ]
          && noSourceDiagnostic.translatedAddressOrPrefix == [ ]
          && noSourceDiagnostic.translatedAddressOrPrefixState == "unavailable"
          && noSourceDiagnostic.addressFamily == 6
          && noSourceDiagnostic.tenantIsolationBoundary.sourcePrefixes == [ ]
          && noSourceDiagnostic.fallback.unmodeledEgress == false
          && noSourceDiagnostic.fallback.untranslatedUlaRoute == false
          && noSourceDiagnostic.fallback.alternateProviders == false
          && noSourceDiagnostic.selectedUplinks == [ "wan" ]
          && noSourceDiagnostic.message == "ULA NAT66 was selected without any ULA source-prefix binding.";
      };
      context = {
        nat66 = nat66;
        noAuthority = noAuthority;
        noWanTranslation = noWanTranslation;
        noIntent = noIntent;
        noSource = noSource;
      };
    }
  ' >"${output_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${output_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL ula-nat66-explicit-contract" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  echo "resolved context:" >&2
  jq '.context' "${output_json}" >&2
  exit 1
fi

echo "PASS ula-nat66-explicit-contract"
