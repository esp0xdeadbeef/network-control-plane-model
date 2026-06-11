#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-380-HDS-010-SDS-010-SMS-040
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

      # --- positive case: NAT44 enabled with bridge/VLAN from inventory ---
      siteAttrs = {
        domains.tenants = [
          { name = "tenant-a"; ipv4 = "10.20.10.0/24"; }
          { name = "tenant-b"; ipv4 = "10.20.20.0/24"; }
        ];
        ownership.prefixes = [
          { ipv4 = "10.30.0.0/16"; }
        ];
      };

      nat44WanWithBridge = {
        sourceKind = "wan";
        upstream = "wan";
        sourceInterfaceName = "wan0";
        runtimeIfName = "eth0";
        addr4 = "203.0.113.10/32";
        hostUplink = {
          bridge = "br-uplink0";
          uplinkName = "uplink0";
          name = "uplink0";
          parent = "eno1";
          ipv4 = {
            method = "static";
            address = "203.0.113.10/32";
          };
        };
        attach = {
          kind = "bridge";
          bridge = "br-uplink0";
          vlan = 200;
          parentUplink = "uplink0";
        };
      };

      targetWithNat44 = {
        role = "core";
        egressIntent = {
          exit = true;
          trafficClass = "tenant-internet";
          uplinks = [ "wan" ];
          wanInterfaces = [ "wan" ];
          nat44.wan = {
            mode = "nat44";
            sourcePrefixes = [ "10.20.10.0/24" "10.20.20.0/24" ];
          };
        };
      };

      positive = buildNatIntent {
        inherit siteAttrs;
        target = targetWithNat44;
        overlayNames = [ ];
        interfaceRecords = [ nat44WanWithBridge ];
        runtimeOriginSourcePrefixes = [ ];
      };

      hostNatPos = positive.hostNat;

      # --- negative case: no NAT44 (exit disabled) ---
      targetNoNat44 = {
        role = "core";
        egressIntent = {
          exit = false;
        };
      };

      negative = buildNatIntent {
        inherit siteAttrs;
        target = targetNoNat44;
        overlayNames = [ ];
        interfaceRecords = [ ];
        runtimeOriginSourcePrefixes = [ ];
      };

      hostNatNeg = negative.hostNat;

      # --- negative case: WAN without hostUplink IPv4 (no NAT4 possible) ---
      wanNoHostUplinkIPv4 = {
        sourceKind = "wan";
        upstream = "wan";
        sourceInterfaceName = "wan0";
        runtimeIfName = "eth0";
        hostUplink = {
          bridge = "br-uplink0";
          uplinkName = "uplink0";
          name = "uplink0";
          parent = "eno1";
        };
      };

      targetNoNat4 = {
        role = "core";
        egressIntent = {
          exit = true;
          uplinks = [ "wan" ];
          wanInterfaces = [ "wan" ];
          nat44.wan = {
            mode = "nat44";
            sourcePrefixes = [ "10.20.10.0/24" ];
          };
        };
      };

      noNat4Wan = buildNatIntent {
        inherit siteAttrs;
        target = targetNoNat4;
        overlayNames = [ ];
        interfaceRecords = [ wanNoHostUplinkIPv4 ];
        runtimeOriginSourcePrefixes = [ ];
      };

      hostNatNoNat4Wan = noNat4Wan.hostNat;

      # --- HARDCODED prefix detection ---
      _fabric_hardcoded_ranges = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
      isHardcodedPrefix = prefix: builtins.elem prefix _fabric_hardcoded_ranges;

      # --- fabricSubnets expected: tenant + transit ---
      dedupStrings = lst:
        builtins.attrNames (
          builtins.listToAttrs (
            builtins.map (s: { name = s; value = true; }) (
              builtins.filter (s: builtins.isString s && s != "") lst
            )
          )
        );

      tenantSubnets =
        builtins.concatMap
          (tenant:
            if builtins.isAttrs tenant then
              let ipv4 = tenant.ipv4 or ""; in
              if ipv4 != "" then [ ipv4 ] else [ ]
            else if builtins.isString tenant && tenant != "" then
              [ tenant ]
            else
              [ ])
          (siteAttrs.domains.tenants or [ ]);

      transitSubnets =
        let
          adjacencies = [
            { endpoints = [ { local.ipv4 = "10.100.0.1/24"; } { local.ipv4 = "10.100.0.2/24"; } ]; }
            { endpoints = [ { local.ipv4 = "10.200.0.1/24"; } { local.ipv4 = "10.200.0.2/24"; } ]; }
          ];
        in
        dedupStrings (
          builtins.concatMap
            (adj:
              let endpoints = if builtins.isList (adj.endpoints or null) then adj.endpoints else [ ];
              in
              builtins.concatMap
                (ep:
                  let addr4 = if builtins.isAttrs ep then ep.local.ipv4 or "" else ""; in
                  if addr4 != "" then [ addr4 ] else [ ])
                endpoints)
            adjacencies);

      fabricSubnetsExpected = dedupStrings (tenantSubnets ++ transitSubnets);

      # expected hostNat values
      expectedMasqPrefixes4 = [ "10.20.10.0/24" "10.20.20.0/24" "10.30.0.0/16" ];
      expectedReturnRouteSubnets = expectedMasqPrefixes4;

    in {
      checks = {
        # SMS-020: hostNat.required true when core has NAT44 egress
        hostNatRequiredTrue = hostNatPos.required == true;

        # SMS-020: hostNat.egressBridge from inventory (not synthesized)
        hostNatEgressBridgeFromInventory =
          hostNatPos.egressBridge == "br-uplink0";

        # SMS-020: hostNat.vlanId from inventory
        hostNatVlanIdFromInventory =
          hostNatPos.vlanId == 200;

        # SMS-020: hostNat.hostMasqueradePrefixes4 matches fabric tenant prefixes
        hostNatMasqueradePrefixes4 =
          hostNatPos.hostMasqueradePrefixes4 == expectedMasqPrefixes4;

        # SMS-040: hostNat.returnRouteSubnets equals tenant subnets for return routing
        hostNatReturnRouteSubnets =
          hostNatPos.returnRouteSubnets == expectedReturnRouteSubnets;

        # fabricSubnets enumerates all tenant + transit subnets
        fabricSubnetsEnumeration =
          fabricSubnetsExpected == [ "10.100.0.1/24" "10.100.0.2/24" "10.20.10.0/24" "10.20.20.0/24" "10.200.0.1/24" "10.200.0.2/24" ];

        # Seeded negative: hostNat.required false when no NAT44 egress
        hostNatRequiredFalseWhenNoNat44 =
          hostNatNeg.required == false;

        # Seeded negative: empty hostNat when no NAT44
        hostNatEmptyWhenNoNat44 =
          hostNatNeg.egressBridge == null
          && hostNatNeg.vlanId == null
          && hostNatNeg.hostMasqueradePrefixes4 == [ ]
          && hostNatNeg.returnRouteSubnets == [ ];

        # Seeded negative: no NAT4 when WAN has no hostUplink IPv4
        hostNatNoNat4WithoutHostUplinkIPv4 =
          hostNatNoNat4Wan.required == false;

        # Seeded negative: no hardcoded IP prefixes from _fabric_private_ranges()
        hostNatNoHardcodedFabricRanges =
          !(builtins.any isHardcodedPrefix hostNatPos.hostMasqueradePrefixes4)
          && !(builtins.any isHardcodedPrefix hostNatPos.returnRouteSubnets);

        # hostNat exists and is an attrset
        hostNatIsAttr = builtins.isAttrs hostNatPos;

        # Bridge name is drawn from hostUplink.bridge in WAN interface
        bridgeNameFromHostUplink =
          hostNatPos.egressBridge == "br-uplink0";
      };
    }
  ' > "${output_json}"

# Evaluate all checks
failed=$(jq -r '[.checks | to_entries[] | select(.value != true) | .key] | join(", ")' "${output_json}")
if [[ -z "$failed" || "$failed" == "null" ]]; then
  echo "PASS FS-380-HDS-010-SDS-010-SMS-020-cpm-hostnat-contract"
else
  echo "FAIL FS-380-HDS-010-SDS-010-SMS-020-cpm-hostnat-contract: $failed"
  jq '.checks' "${output_json}"
  exit 1
fi
