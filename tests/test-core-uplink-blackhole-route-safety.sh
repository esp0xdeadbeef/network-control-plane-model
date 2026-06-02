#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-CORE-UPLINK-BLACKHOLE-ROUTE-SAFETY-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-001-SMS-001-CMC-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-006
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-007
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-008
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-009
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-006
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-007
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-008
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-009
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-006
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-CMC-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-003-SMS-001-CMC-001-006
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-001
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-002
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-003
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-004
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-001
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-002
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-003
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-004
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

cd "${repo_root}"
missing_error="$(mktemp)"
declined_error="$(mktemp)"
trap 'rm -f "${missing_error}" "${declined_error}"' EXIT

expr='
    let
      flake = builtins.getFlake ("path:" + toString ./.);
      system = builtins.currentSystem;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      lib = pkgs.lib;
      helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
      buildNatIntent = import ./src/cpm/firewall-intent/nat.nix { inherit helpers; };
      wanInterface = {
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
        wan.egress.ipv6.translation.mode = "nat66";
      };
      transitInterface = {
        sourceKind = "p2p";
        runtimeIfName = "transit";
      };
      baseTarget = {
        role = "core";
        egressIntent = {
          exit = true;
          uplinks = [ "wan" ];
          wanInterfaces = [ "wan" ];
          interfaceDeclineList = [ "unselected-disabled0" ];
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
      natFor = target:
        buildNatIntent {
          siteAttrs = { };
          overlayNames = [ ];
          interfaceRecords = [ wanInterface transitInterface ];
          target = target;
          runtimeOriginSourcePrefixes = [
            { family = 4; prefix = "10.19.0.8/32"; }
            { family = 6; prefix = "fd42:dead:beef:1900::8/128"; }
          ];
        };
      blackholedNat = natFor baseTarget;
      blackholedSafety = blackholedNat.routeSafety.coreOriginUplinkDefault;
      allowedNat = natFor (
        baseTarget
        // {
          egressIntent = baseTarget.egressIntent // { coreOriginUplinkDefaultAllowed = true; };
        }
      );
      allowedSafety = allowedNat.routeSafety.coreOriginUplinkDefault;
    in
      blackholedSafety.applies == true
      && blackholedNat.masqueradeSourcePrefixes4 == [
        "10.19.0.8/32"
        "10.20.10.0/24"
      ]
      && blackholedNat.masqueradeInterfaces4 == [ "eth0" ]
      && blackholedSafety.mode == "blackholed"
      && blackholedSafety.blackholed == true
      && blackholedSafety.broadCoreOriginUplinkRoutingAllowed == false
      && blackholedSafety.selectedUplinks == [ "wan" ]
      && blackholedSafety.selectedUplinkInterfaces == [ "eth0" ]
      && blackholedSafety.declinedInterfaces == [ "unselected-disabled0" ]
      && blackholedSafety.sourceScopedTranslationExceptions.nat44 == true
      && blackholedSafety.sourceScopedTranslationExceptions.nat66 == true
      && blackholedSafety.sourceScopedTranslationExceptions.snat == true
      && blackholedSafety.sourceScopedTranslationExceptions.nat44SourcePrefixes == [
        "10.19.0.8/32"
        "10.20.10.0/24"
      ]
      && blackholedSafety.sourceScopedTranslationExceptions.nat66SourcePrefixes == [
        "fd42:dead:beef:10::/64"
        "fd42:dead:beef:1900::8/128"
      ]
      && blackholedSafety.sourceScopedTranslationExceptions.snatSourcePrefixes == [
        "10.19.0.8/32"
        "10.20.10.0/24"
        "fd42:dead:beef:10::/64"
        "fd42:dead:beef:1900::8/128"
      ]
      && blackholedSafety.sourceScopedTranslationExceptions.nat44Boundaries == [ "wan" ]
      && blackholedSafety.sourceScopedTranslationExceptions.nat66Boundaries == [ "wan" ]
      && blackholedSafety.sourceScopedTranslationExceptions.snatBoundaries == [ "wan" ]
      && blackholedSafety.sourceScopedTranslationExceptions.nat44OutputInterfaces == [ "eth0" ]
      && blackholedSafety.sourceScopedTranslationExceptions.nat66OutputInterfaces == [ "eth0" ]
      && blackholedSafety.sourceScopedTranslationExceptions.outputInterfaces == [ "eth0" ]
      && allowedSafety.applies == true
      && allowedSafety.mode == "explicitly-allowed"
      && allowedSafety.blackholed == false
      && allowedSafety.broadCoreOriginUplinkRoutingAllowed == true
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "${expr}" | grep -qx true; then
  echo "PASS core-uplink-blackhole-route-safety"
else
  echo "FAIL core-uplink-blackhole-route-safety" >&2
  exit 1
fi

missing_expr='
    let
      flake = builtins.getFlake ("path:" + toString ./.);
      system = builtins.currentSystem;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      lib = pkgs.lib;
      helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
      buildNatIntent = import ./src/cpm/firewall-intent/nat.nix { inherit helpers; };
      wanInterface = {
        sourceKind = "wan";
        upstream = "wan";
        sourceInterfaceName = "wan0";
        runtimeIfName = "eth0";
        hostUplink.ipv4.method = "dhcp";
      };
    in
      (buildNatIntent {
        siteAttrs = { };
        overlayNames = [ ];
        interfaceRecords = [ wanInterface ];
        target = {
          role = "core";
          egressIntent = {
            exit = true;
            uplinks = [ "missing-wan" ];
            wanInterfaces = [ "missing-wan" ];
          };
        };
      }).routeSafety.coreOriginUplinkDefault.selectedUplinkInterfaces
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "${missing_expr}" >/dev/null 2>"${missing_error}"; then
  echo "FAIL core-uplink-blackhole-route-safety: missing selected uplink was accepted" >&2
  exit 1
fi

if ! rg -q "selected uplink.*not realized as WAN interface" "${missing_error}"; then
  echo "FAIL core-uplink-blackhole-route-safety: missing selected uplink diagnostic was not specific" >&2
  cat "${missing_error}" >&2
  exit 1
fi

declined_expr='
    let
      flake = builtins.getFlake ("path:" + toString ./.);
      system = builtins.currentSystem;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      lib = pkgs.lib;
      helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
      buildNatIntent = import ./src/cpm/firewall-intent/nat.nix { inherit helpers; };
      wanInterface = {
        sourceKind = "wan";
        upstream = "wan";
        sourceInterfaceName = "wan0";
        runtimeIfName = "eth0";
        hostUplink.ipv4.method = "dhcp";
      };
    in
      (buildNatIntent {
        siteAttrs = { };
        overlayNames = [ ];
        interfaceRecords = [ wanInterface ];
        target = {
          role = "core";
          egressIntent = {
            exit = true;
            uplinks = [ "wan" ];
            wanInterfaces = [ "wan" ];
            interfaceDeclineList = [ "eth0" ];
          };
        };
      }).routeSafety.coreOriginUplinkDefault.selectedUplinkInterfaces
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "${declined_expr}" >/dev/null 2>"${declined_error}"; then
  echo "FAIL core-uplink-blackhole-route-safety: declined selected uplink was accepted" >&2
  exit 1
fi

if ! rg -q "selected uplink.*declined interface identities" "${declined_error}"; then
  echo "FAIL core-uplink-blackhole-route-safety: declined selected uplink diagnostic was not specific" >&2
  cat "${declined_error}" >&2
  exit 1
fi
