#!/usr/bin/env bash
# GAMP-ID: FS-530-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

nix_expr_bindings() {
  printf '%s\n' '
    repoRoot = builtins.getEnv "REPO_ROOT";
    lib = import <nixpkgs/lib>;
    helpers = import (repoRoot + "/lib/contract.nix") { inherit lib; };
    common = {
      attrsOrEmpty = value: if builtins.isAttrs value then value else {};
      listOrEmpty = value: if builtins.isList value then value else [];
      failInventory = path: message: builtins.throw "inventory.nix update required: ${path}: ${message}";
    };
    endpointInventoryIndex = { byIPv4 = {}; byIPv6 = {}; };
    advertisementHelpers = import (repoRoot + "/src/cpm/Unit/access-advertisements/helpers.nix") {
      inherit helpers endpointInventoryIndex;
    };
    dnsContracts = import (repoRoot + "/src/cpm/ControlModule/runtime-targets/dns-contracts.nix") {
      inherit lib helpers common;
      policyDerivedDnsAllowedClassesForListeners = listeners: [ "local-access" ];
      policyDerivedDnsForwardersForListeners = listeners: [];
      policyDerivedDnsUpstreamRecordsForListeners = listeners: [];
    };
    validTarget = {
      role = "access";
      placement.target = "access-runtime";
      services.dns = {};
      advertisements = {
        dhcp4 = [{
          interface = "tenant-client";
          bindInterface = "tenant-client";
          tenant = "client";
          dnsServers = [ "10.20.20.1" ];
          subnet = "10.20.20.0/24";
        }];
        ipv6Ra = [{
          interface = "tenant-client";
          bindInterface = "tenant-client";
          tenant = "client";
          rdnss = [ "fd42:dead:beef:20::1" ];
          prefixes = [ "fd42:dead:beef:20::/64" ];
        }];
      };
    };
  '
}

positive_expr="let
  $(nix_expr_bindings)
  result = dnsContracts validTarget;
  records = result.advertisements.resolverAdvertisements or [];
  dhcp4 = builtins.elemAt records 0;
  ra = builtins.elemAt records 1;
in
  builtins.length records == 2
  && (
    dhcp4.kind == \"dns-resolver-advertisement\"
    && dhcp4.transport == \"dhcp4\"
    && dhcp4.requiredDiscoveryOption == \"dhcp-option-6\"
    && dhcp4.addressFamily == \"ipv4\"
    && dhcp4.requesterScope == \"access-runtime\"
    && dhcp4.resolverAddress == \"10.20.20.1\"
    && dhcp4.sourceInterface == \"tenant-client\"
    && dhcp4.attachmentSurface == \"tenant-client\"
    && dhcp4.resolverPurpose == \"client-recursive-resolver-candidate\"
    && dhcp4.policyReferences.routeContract.source == \"router-self\"
    && dhcp4.policyReferences.trafficClassification.dnsPolicy == \"modeled-resolver-relationship\"
    && dhcp4.advertisementGrantsRecursion == false
    && dhcp4.advertisementGrantsUpstreamForwarding == false
    && dhcp4.advertisementGrantsPublicDnsEgress == false
  )
  && (
    ra.transport == \"ipv6-ra\"
    && ra.requiredDiscoveryOption == \"ra-rdnss\"
    && ra.addressFamily == \"ipv6\"
    && ra.resolverAddress == \"fd42:dead:beef:20::1\"
    && ra.policyReferences.routeContract.source == \"router-self\"
    && ra.policyReferences.trafficClassification.dnsPolicy == \"modeled-resolver-relationship\"
  )"

if ! REPO_ROOT="${repo_root}" nix eval --impure --expr "${positive_expr}" | grep -qx true; then
  echo "FAIL FS-530 resolver advertisement contract: expected complete DHCP4 and RA records" >&2
  exit 1
fi

missing_policy_expr="let
  $(nix_expr_bindings)
  badTarget = builtins.removeAttrs validTarget [ \"services\" ];
in
  dnsContracts badTarget"

if REPO_ROOT="${repo_root}" nix eval --impure --expr "${missing_policy_expr}" >/tmp/fs530-missing-policy.out 2>/tmp/fs530-missing-policy.err; then
  echo "FAIL FS-530 resolver advertisement contract: missing DNS policy unexpectedly passed" >&2
  exit 1
fi

if ! grep -q "missing modeled DNS policy for resolver advertisement" /tmp/fs530-missing-policy.err; then
  echo "FAIL FS-530 resolver advertisement contract: missing-policy diagnostic was not specific" >&2
  cat /tmp/fs530-missing-policy.err >&2
  exit 1
fi

missing_dhcp4_option_expr="let
  $(nix_expr_bindings)
in
  advertisementHelpers.resolveAdvertisedIPv4Targets
    \"inventory.realization.nodes.access.advertisements.dhcp4.tenant-client\"
    \"dnsServers\"
    \"10.20.20.1\"
    null"

if REPO_ROOT="${repo_root}" nix eval --impure --expr "${missing_dhcp4_option_expr}" >/tmp/fs530-missing-dhcp4.out 2>/tmp/fs530-missing-dhcp4.err; then
  echo "FAIL FS-530 resolver advertisement contract: missing DHCP option 6 unexpectedly passed" >&2
  exit 1
fi

if ! grep -q "enabled resolver advertisement must explicitly define DNS discovery targets" /tmp/fs530-missing-dhcp4.err; then
  echo "FAIL FS-530 resolver advertisement contract: missing DHCP option diagnostic was not specific" >&2
  cat /tmp/fs530-missing-dhcp4.err >&2
  exit 1
fi

missing_ra_option_expr="let
  $(nix_expr_bindings)
in
  advertisementHelpers.resolveAdvertisedIPv6Targets
    \"inventory.realization.nodes.access.advertisements.ipv6Ra.tenant-client\"
    \"rdnss\"
    \"fd42:dead:beef:20::1\"
    null"

if REPO_ROOT="${repo_root}" nix eval --impure --expr "${missing_ra_option_expr}" >/tmp/fs530-missing-ra.out 2>/tmp/fs530-missing-ra.err; then
  echo "FAIL FS-530 resolver advertisement contract: missing RA RDNSS unexpectedly passed" >&2
  exit 1
fi

if ! grep -q "enabled resolver advertisement must explicitly define DNS discovery targets" /tmp/fs530-missing-ra.err; then
  echo "FAIL FS-530 resolver advertisement contract: missing RA RDNSS diagnostic was not specific" >&2
  cat /tmp/fs530-missing-ra.err >&2
  exit 1
fi

echo "PASS FS-530-HDS-010-SDS-010-SMS-010 dns resolver advertisement contract"
