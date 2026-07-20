#!/usr/bin/env bash
# GAMP-ID: FS-350-HDS-010-SDS-010-SMS-060
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

result="$({ REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    root = builtins.getEnv "REPO_ROOT";
    isNonEmptyString = value: builtins.isString value && value != "";
    helpers = { inherit isNonEmptyString; };
    common = {
      listOrEmpty = value: if builtins.isList value then value else [ ];
      attrsOrEmpty = value: if builtins.isAttrs value then value else { };
      mergeRoutes = left: right: {
        ipv4 = (left.ipv4 or [ ]) ++ (right.ipv4 or [ ]);
        ipv6 = (left.ipv6 or [ ]) ++ (right.ipv6 or [ ]);
      };
    };
    lib = {
      unique = values: values;
      concatMap = f: values: builtins.concatLists (builtins.map f values);
      mapAttrs = builtins.mapAttrs;
    };
    prefix = {
      family = "ipv6";
      name = "vlan2-public";
      tenant = "vlan2";
      sourceFile = "/run/secrets/subnet-ipv6-vlan2";
      delegatedPrefixLength = 48;
      perTenantPrefixLength = 64;
      slot = 2;
      prefixPostfix = "0042";
    };
    expected = route:
      route.sourceFile == prefix.sourceFile
      && route.tenant == "vlan2"
      && route.delegatedPrefixLength == 48
      && route.perTenantPrefixLength == 64
      && route.slot == 2
      && route.prefixPostfix == "0042";
    directBuilder = import (root + "/src/cpm/Unit/runtime-targets/interfaces/runtime-routed-prefix-routes.nix") {
      inherit helpers common;
    };
    direct = builtins.head (directBuilder {
      nodeName = "access-vlan2";
      tenantName = "vlan2";
      routedPrefixesByTenant = { vlan2 = [ prefix ]; };
    }).ipv6;
    missing = builtins.tryEval (builtins.deepSeq (directBuilder {
      nodeName = "access-vlan2";
      tenantName = "vlan2";
      routedPrefixesByTenant = {
        vlan2 = [ (builtins.removeAttrs prefix [ "slot" ]) ];
      };
    }) true);
    overlayPrefix = prefix // {
      family = 6;
      prefixName = prefix.name;
    };
    overlayProvisioning = {
      east = {
        peerTenantPrefixes = [ ];
        peerRuntimeRoutedPrefixes = [ overlayPrefix ];
      };
    };
    policyBuilder = import (root + "/src/cpm/Unit/runtime-targets/overlay-route-augmentation/policy-uplink-returns.nix") {
      inherit lib common helpers overlayProvisioning;
    };
    policy = builtins.head (policyBuilder 6 { access = "vlan2"; uplink = "wan"; } "fd00::1");
    wanBuilder = import (root + "/src/cpm/Unit/runtime-targets/overlay-route-augmentation/wan-core-returns.nix") {
      inherit lib common helpers overlayProvisioning;
      p2pPeerAddress = _family: _address: "fd00::1";
    };
    wan = builtins.head ((wanBuilder "core" {
      uplink = {
        sourceKind = "p2p";
        addr6 = "fd00::2/127";
        backingRef.lane = { kind = "uplink"; uplink = "wan"; };
        routes = { ipv4 = [ ]; ipv6 = [ ]; };
      };
    }).uplink.routes.ipv6);
  in {
    direct = expected direct && direct.prefixName == "vlan2-public";
    policy = expected policy;
    wan = expected wan;
    missingRejected = missing.success == false;
  }
'; } )"

jq -e '
  .direct == true
  and .policy == true
  and .wan == true
  and .missingRejected == true
' <<<"${result}" >/dev/null || {
  printf 'FAIL FS-350-HDS-010-SDS-010-SMS-060: runtime route lost or defaulted delegated-prefix derivation metadata\n' >&2
  exit 1
}

printf 'PASS FS-350-HDS-010-SDS-010-SMS-060 runtime delegated route metadata\n'
