#!/usr/bin/env bash
# GAMP-ID: FS-420-HDS-010-SDS-010-SMS-020
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
      siteAttrs = {
        domains.tenants = [
          {
            name = "tenant-a";
            ipv4 = "10.20.10.0/24";
            ipv6 = "fd42:dead:beef:10::/64";
          }
        ];
      };
      nat44Wan = {
        sourceKind = "wan";
        upstream = "wan";
        sourceInterfaceName = "wan0";
        runtimeIfName = "eth0";
        addr4 = "203.0.113.10/32";
        hostUplink = {
          ipv4 = {
            method = "static";
            address = "203.0.113.10/32";
          };
          ipv6 = {
            method = "slaac";
            egressAuthority = true;
          };
        };
      };
      nat66Wan = nat44Wan // {
        wan.egress.ipv6.translation = {
          mode = "nat66";
          translatedPrefix = "2001:db8:420::/64";
        };
      };
      noAuthorityWan = nat66Wan // {
        hostUplink.ipv6 = {
          method = "slaac";
        };
      };
      target = {
        role = "core";
        egressIntent = {
          exit = true;
          trafficClass = "tenant-internet";
          uplinks = [ "wan" ];
          wanInterfaces = [ "wan" ];
          nat44.wan = {
            mode = "nat44";
            sourcePrefixes = [ "10.20.10.0/24" ];
          };
          nat66.wan = {
            mode = "nat66";
            sourcePrefixes = [ "fd42:dead:beef:10::/64" ];
          };
        };
      };
      natFor = interfaces:
        buildNatIntent {
          inherit siteAttrs target;
          overlayNames = [ ];
          interfaceRecords = interfaces;
          runtimeOriginSourcePrefixes = [ ];
        };
      selected = natFor [ nat66Wan ];
      selectedNat44 = builtins.head (builtins.filter (record: record.family == 4) selected.translationRecords);
      selectedNat66 = builtins.head (builtins.filter (record: record.family == 6) selected.translationRecords);
      noAuthority = natFor [ noAuthorityWan ];
    in {
      checks = {
        emitsOnlySelectedTranslations = builtins.length selected.translationRecords == 2;
        nat44RecordPreservesSelectedScope =
          selectedNat44.mode == "nat44"
          && selectedNat44.sourceScope == [ "10.20.10.0/24" ]
          && selectedNat44.translatedAddressOrPrefix == [ "203.0.113.10/32" ]
          && selectedNat44.translatedAddressOrPrefixState == "explicit"
          && selectedNat44.egressSurface.selectedUplinks == [ "wan" ]
          && selectedNat44.egressSurface.selectedUplinkInterfaces == [ "eth0" ]
          && selectedNat44.tenantIsolationBoundary == {
            kind = "tenant-source-prefix";
            tenants = [ "tenant-a" ];
            sourcePrefixes = [ "10.20.10.0/24" ];
          }
          && selectedNat44.returnBehavior == {
            broadCoreOriginUplinkDefault = "blackholed";
            sourceScopedException = true;
          }
          && selectedNat44.consumers == [ "routing" "firewall" "renderer" "diagnostic" ];
        nat66RecordPreservesExplicitTranslation =
          selectedNat66.mode == "nat66"
          && selectedNat66.sourceScope == [ "fd42:dead:beef:10::/64" ]
          && selectedNat66.translatedAddressOrPrefix == [ "2001:db8:420::/64" ]
          && selectedNat66.translatedAddressOrPrefixState == "explicit"
          && selectedNat66.egressSurface.selectedUplinks == [ "wan" ]
          && selectedNat66.egressSurface.selectedUplinkInterfaces == [ "eth0" ]
          && selectedNat66.tenantIsolationBoundary == {
            kind = "tenant-source-prefix";
            tenants = [ "tenant-a" ];
            sourcePrefixes = [ "fd42:dead:beef:10::/64" ];
          }
          && selectedNat66.returnBehavior == {
            broadCoreOriginUplinkDefault = "blackholed";
            sourceScopedException = true;
          }
          && selectedNat66.consumers == [ "routing" "firewall" "renderer" "diagnostic" ];
        noAuthorityEmitsNoTranslationRecord =
          noAuthority.translationRecords == [ ]
          && noAuthority.diagnostics.nat66 != [ ];
      };
      context = {
        inherit selected noAuthority;
      };
    }
  ' >"${output_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${output_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL fs420-translation-record-emission" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  echo "resolved context:" >&2
  jq '.context' "${output_json}" >&2
  exit 1
fi

echo "PASS fs420-translation-record-emission"
