#!/usr/bin/env bash
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-002
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-003
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-004
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-005
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-002
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-003
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-004
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-005
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-004-SMS-001-003
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-004-SMS-001-CMC-001-003
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
      expectedSourcePrefixes = [
        "fd42:dead:beef:10::/64"
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
        noEgressAuthorityDisablesNat66 = noAuthority.families.ipv6 == false && noAuthority.masqueradeSourcePrefixes6 == [ ] && noAuthority.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false && noAuthority.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66OutputInterfaces == [ ];
        noWanTranslationDisablesNat66 = noWanTranslation.families.ipv6 == false && noWanTranslation.masqueradeSourcePrefixes6 == [ ] && noWanTranslation.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false && noWanTranslation.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66SourcePrefixes == [ ];
        noNat66IntentDisablesNat66 = noIntent.families.ipv6 == false && noIntent.masqueradeSourcePrefixes6 == [ ] && noIntent.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false && noIntent.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66SourcePrefixes == [ ];
        noSourceScopeDisablesNat66 = noSource.families.ipv6 == false && noSource.masqueradeSourcePrefixes6 == [ ] && noSource.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false && noSource.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66SourcePrefixes == [ ];
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
