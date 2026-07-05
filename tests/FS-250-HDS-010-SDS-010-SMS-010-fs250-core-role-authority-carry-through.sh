#!/usr/bin/env bash
# GAMP-ID: FS-250-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-250-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

expr_nix="${tmpdir}/fs250-core-role-authority-carry-through.nix"
result_json="${tmpdir}/fs250-core-role-authority-carry-through.json"

cat >"${expr_nix}" <<'NIX'
let
  repoRoot = builtins.getEnv "REPO_ROOT";
  buildValue = import (repoRoot + "/src/cpm/Unit/runtime-targets/build-value.nix") {
    requireString =
      path: value:
      if builtins.isString value && value != "" then value else throw "${path} is required";
    bgpSiteAsn = 64512;
    bgpNeighborsForNode = _nodeName: [ ];
    ebgpNeighborsForTarget = _isBgpRouter: _interfaces: [ ];
    bgpNetworksForNode = _nodeRole: _nodeAttrs: _interfaces: [ ];
  };

  minimalCoreAuthority = {
    role = "core";
    egressIntent = {
      eligible = true;
      exit = true;
      explicit = true;
      externalDomains = [ "wan" ];
      nat66 = { };
      uplinks = [ "wan" ];
      upstreamSelection = false;
      wanInterfaces = [ "wan0" ];
    };
    forwardingFunctions = [
      "router-identity"
      "transit-forwarder"
      "external-egress"
      "uplink-anchor"
    ];
    forwardingResponsibility = {
      anchorsExternalUplinks = true;
      carriesTransit = true;
      enforcesPolicy = false;
      explicit = true;
      participatesInUpstreamSelection = true;
      terminatesOverlays = false;
      terminatesTenants = false;
    };
    routingAuthority = {
      connectedReachability = true;
      defaultReachability = false;
      exitsSite = true;
      explicit = true;
      internalReachability = true;
      overlayReachability = false;
      selectsUpstream = false;
      uplinkLearnedReachability = false;
    };
    traversalParticipation = {
      enforcement = false;
      exit = true;
      explicit = true;
      ingress = false;
      participates = true;
      transit = true;
      upstreamSelection = false;
    };
  };

  providerAndPlacementFacts = {
    sharedHost = "shared-core-access-provider-host";
    coLocatedRoles = [ "access" "resolver" "management" "public-ingress" ];
    providerProfile = "isp";
    routeAvailability = {
      default = true;
      tenant = true;
      service = true;
    };
  };

  effectiveRuntimeInterfaces = {
    wan0 = {
      interface = "eth0";
      kind = "wan";
      routes.ipv4 = [
        {
          dst = "0.0.0.0/0";
          proto = "dhcp";
          source = "route-availability";
        }
      ];
      providerProfile = "isp";
    };
    tenant0 = {
      interface = "tenant0";
      kind = "tenant";
      tenant = "client";
    };
    mgmt0 = {
      interface = "mgmt0";
      kind = "management";
    };
  };

  target = buildValue {
    nodePath = "enterprise.site.nodes.core";
    nodeName = "core";
    nodeAttrs = minimalCoreAuthority;
    logical = {
      enterprise = "enterprise";
      site = "site";
      name = "core";
    };
    isBgpRouter = false;
    placement = providerAndPlacementFacts;
    loopback = {
      ipv4 = "10.250.0.1";
      ipv6 = "fd00:250::1";
    };
    inherit effectiveRuntimeInterfaces;
    nodeRole = "core";
    runtimeContainers = [ ];
    runtimeOriginEgressContract = null;
    runtimeServices = null;
    hasRuntimeServices = false;
    runtimeStatePolicy = { };
    runtimeDiagnostics = { };
  };

  forbiddenFunctions = [
    "access-gateway"
    "tenant-edge"
    "resolver"
    "recursive-resolver"
    "management"
    "public-ingress"
    "payload"
  ];

  hasForbiddenFunction =
    node:
    builtins.any (name: builtins.elem name (node.forwardingFunctions or [ ])) forbiddenFunctions;

  checks = {
    forwardingFunctionsCopiedOnly = target.forwardingFunctions == minimalCoreAuthority.forwardingFunctions;
    forwardingResponsibilityCopiedOnly = target.forwardingResponsibility == minimalCoreAuthority.forwardingResponsibility;
    routingAuthorityCopiedOnly = target.routingAuthority == minimalCoreAuthority.routingAuthority;
    traversalParticipationCopiedOnly = target.traversalParticipation == minimalCoreAuthority.traversalParticipation;
    egressIntentCopiedOnly = target.egressIntent == minimalCoreAuthority.egressIntent;
    placementDidNotTerminateTenants = target.forwardingResponsibility.terminatesTenants == false;
    routeAvailabilityDidNotCreateDefault = target.routingAuthority.defaultReachability == false;
    providerProfileDidNotCreateUnrelatedFunction = !(hasForbiddenFunction target);
    noServiceAuthorityInvented = !(target ? services);
    noRuntimeOriginEgressInvented = !(target ? runtimeOriginEgress);
  };
in
{
  inherit target checks;
}
NIX

REPO_ROOT="${repo_root}" nix eval \
  --extra-experimental-features 'nix-command flakes' \
  --impure --json --file "${expr_nix}" >"${result_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${result_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL fs250-core-role-authority-carry-through" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  jq '.' "${result_json}" >&2
  exit 1
fi

echo "PASS fs250-core-role-authority-carry-through"
