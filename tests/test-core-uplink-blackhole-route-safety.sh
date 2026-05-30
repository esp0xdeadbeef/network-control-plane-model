#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-CORE-UPLINK-BLACKHOLE-ROUTE-SAFETY-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

cd "${repo_root}"

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
          ipv6 = { method = "slaac"; };
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
      && blackholedSafety.mode == "blackholed"
      && blackholedSafety.blackholed == true
      && blackholedSafety.broadCoreOriginUplinkRoutingAllowed == false
      && blackholedSafety.selectedUplinks == [ "wan" ]
      && blackholedSafety.sourceScopedTranslationExceptions.nat44 == true
      && blackholedSafety.sourceScopedTranslationExceptions.nat66 == true
      && blackholedSafety.sourceScopedTranslationExceptions.snat == true
      && blackholedSafety.sourceScopedTranslationExceptions.nat66SourcePrefixes == [
        "fd42:dead:beef:10::/64"
        "fd42:dead:beef:1900::8/128"
      ]
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
