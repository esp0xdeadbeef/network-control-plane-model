#!/usr/bin/env bash
# GAMP-ID: FS-270-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

expr_nix="${tmpdir}/fs270-transit-host-local-separation.nix"
result_json="${tmpdir}/fs270-transit-host-local-separation.json"

cat >"${expr_nix}" <<'NIX'
let
  repoRoot = builtins.getEnv "REPO_ROOT";
  buildForwarding = import (repoRoot + "/src/cpm/firewall-intent/forwarding.nix") {
    helpers = { };
  };

  tenantIface = {
    sourceKind = "tenant";
    sourceInterfaceName = "tenant0";
    runtimeIfName = "tenant0";
    routes.ipv4 = [
      {
        dst = "0.0.0.0/0";
        proto = "provider-default";
        source = "route-availability";
      }
    ];
  };

  managementIface = {
    sourceKind = "management";
    sourceInterfaceName = "mgmt0";
    runtimeIfName = "mgmt0";
    routes.ipv4 = [
      {
        dst = "0.0.0.0/0";
        proto = "provider-default";
        source = "route-availability";
      }
    ];
  };

  transitIface = {
    sourceKind = "p2p";
    sourceInterfaceName = "policy-core";
    runtimeIfName = "policy-core0";
    backingRef.lane = {
      kind = "access-uplink";
      access = "client";
      uplink = "wan0";
    };
  };

  alternateTransitIface = {
    sourceKind = "p2p";
    sourceInterfaceName = "policy-core-alt";
    runtimeIfName = "policy-core-alt0";
    backingRef.lane = {
      kind = "access-uplink";
      access = "client";
      uplink = "wan0";
    };
  };

  wanIface = {
    sourceKind = "wan";
    sourceInterfaceName = "wan0";
    runtimeIfName = "wan0";
    upstream = "wan0";
    routes.ipv4 = [
      {
        dst = "0.0.0.0/0";
        proto = "provider-default";
        source = "route-availability";
      }
    ];
  };

  pollutedTarget = role: {
    inherit role;
    placement = {
      sharedHost = "host-with-access-policy-core-provider";
      coLocatedRoles = [ "access" "policy" "core" "management" "resolver" "public-ingress" ];
    };
    providerProfile = "provider-with-default-route";
    hostLocalExceptions = {
      management = true;
      resolver = true;
      publicIngress = true;
    };
    egressIntent = {
      explicit = true;
      uplinks = [ "wan0" ];
      wanInterfaces = [ "wan0" ];
    };
  };

  build = role:
    buildForwarding {
      overlayNames = [ ];
      policyEndpointBindings = { };
      services = [ ];
      siteRelations = [ ];
      trafficTypeMatches = { };
      target = pollutedTarget role;
      interfaceRecords = [
        tenantIface
        managementIface
        transitIface
        alternateTransitIface
        wanIface
      ];
      tenantPrefixOwners = { };
      runtimeOriginSourcePrefixes = [ ];
      runtimeTargets = { };
    };

  core = build "core";
  access = build "access";

  ruleIfaces = rule: [
    (rule.fromInterface or null)
    (rule.toInterface or null)
  ];

  mentions = iface: rules:
    builtins.any (rule: builtins.elem iface (ruleIfaces rule)) rules;

  hasRule = fromIface: toIface: rules:
    builtins.any (
      rule:
      (rule.fromInterface or null) == fromIface
      && (rule.toInterface or null) == toIface
    ) rules;

  checks = {
    coreModeIsExplicitCoreForwarding = core.mode == "explicit-core-forwarding";
    coreTransitInterfacesOnlyP2p = core.transitInterfaces == [ "policy-core0" "policy-core-alt0" ];
    coreUplinkInterfacesOnlySelectedWan = core.uplinkInterfaces == [ "wan0" ];
    coreIgnoresTenantHostLocalInterface = !(mentions "tenant0" core.rules);
    coreIgnoresManagementHostLocalInterface = !(mentions "mgmt0" core.rules);
    coreDoesNotUseProviderDefaultAsTenantAuthority = !(hasRule "tenant0" "wan0" core.rules);
    coreDoesNotUseProviderDefaultAsManagementAuthority = !(hasRule "mgmt0" "wan0" core.rules);
    accessModeIsExplicitAccessForwarding = access.mode == "explicit-access-forwarding";
    accessDoesNotBypassTransitToWan = !(hasRule "tenant0" "wan0" access.rules);
    accessUsesTransitRatherThanHostLocalException = hasRule "tenant0" "policy-core0" access.rules;
  };
in
{
  inherit core access checks;
}
NIX

REPO_ROOT="${repo_root}" nix eval \
  --extra-experimental-features 'nix-command flakes' \
  --impure --json --file "${expr_nix}" >"${result_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${result_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL fs270-transit-host-local-separation" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  jq '.' "${result_json}" >&2
  exit 1
fi

echo "PASS fs270-transit-host-local-separation"
