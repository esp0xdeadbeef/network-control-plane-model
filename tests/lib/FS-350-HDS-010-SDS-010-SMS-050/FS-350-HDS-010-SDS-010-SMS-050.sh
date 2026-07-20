#!/usr/bin/env bash
# GAMP-ID: FS-350-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    lib = import <nixpkgs/lib>;
    helpers = import (repoRoot + "/lib/contract.nix") { inherit lib; };
    ipam = import (repoRoot + "/src/cpm/ipam.nix") { inherit lib; };
    common = import (repoRoot + "/src/cpm/Site/build-data/common.nix") {
      inherit helpers ipam;
      enterpriseRoot = { };
    };
    providerAuthorityClassifier = import (repoRoot + "/src/cpm/Site/build-data/provider-authority-classification.nix") {
      inherit helpers common;
    };

    providerAuthority = {
      upstreamType = "overlay-egress";
      providerTechnology = "nebula";
      ipv4Mode = "overlay-host-only";
      ipv6Mode = "overlay-host-only";
      prefixAuthority = {
        routedClient = false;
        delegated = false;
        translated = false;
        source = "provider-authority-record";
      };
      dnsFollowSource = {
        enabled = false;
        source = "provider-authority-record";
      };
      publicIngress = {
        allowed = false;
        source = "provider-authority-record";
      };
      routeAuthority = {
        import = false;
        export = false;
        source = "provider-authority-record";
      };
      nat = {
        nat44 = "none";
        nat66 = "none";
      };
      failureBehavior = "fail-closed";
      expectedClientEgress = "overlay-underlay-bootstrap-only";
      wanEgressRelationship = "policy-selected-provider-egress";
    };

    baseSiteAttrs = {
      overlayReachability = {
        east-west = {
          overlay = "east-west";
          terminateOn = [ "edge" ];
        };
        provider-egress = {
          overlay = "provider-egress";
          terminateOn = [ "edge" ];
        };
      };
      overlayAddressPools = {
        east-west = {
          ipv4.prefix = "100.64.10.0/24";
          ipv6.prefix = "fd42:dead:beef:10::/64";
        };
        provider-egress = {
          ipv4.prefix = "100.64.20.0/24";
          ipv6.prefix = "fd42:dead:beef:20::/64";
        };
      };
    };

    baseSiteOverlays = {
      east-west = {
        provider = "nebula";
        nodes.edge = {
          addr4 = "100.64.10.1/32";
          addr6 = "fd42:dead:beef:10::1/128";
        };
      };
      provider-egress = {
        provider = "nebula";
        inherit providerAuthority;
        nodes.edge = {
          addr4 = "100.64.20.1/32";
          addr6 = "fd42:dead:beef:20::1/128";
        };
      };
    };

    buildOverlayProvisioning = siteOverlays:
      import (repoRoot + "/src/cpm/Site/build-data/overlay-provisioning.nix") {
        inherit lib helpers common ipam;
        allSiteEntries = [ ];
        enterpriseName = "acme";
        inventoryAttrs = { };
        sitePath = "forwardingModel.enterprise.acme.site.ams";
        siteAttrs = baseSiteAttrs;
        inherit siteOverlays;
      };

    provisioning = buildOverlayProvisioning baseSiteOverlays;
    eastWest = provisioning.overlayProvisioning.east-west;
    providerEgress = provisioning.overlayProvisioning.provider-egress;
    eastWestRealization = eastWest.nodes.edge.inventoryRealization;
    providerRealization = providerEgress.nodes.edge.inventoryRealization;
    providerClassification = providerAuthorityClassifier.classify {
      overlayName = "provider-egress";
      overlay = providerEgress;
    };

    hostOnlyEndpoint4 =
      builtins.any
        (record:
          record.family == 4
          && record.address == "100.64.20.1/32"
          && record.classification == "host-only-provider-endpoint"
          && record.hostOnly == true
          && record.clientPrefixAuthority == false)
        providerClassification.endpointClassification.records;

    checks = {
      eastWestPreservesSelectedLedger =
        eastWestRealization.kind == "overlay-participant-address-realization"
        && eastWestRealization.rowId == "FS-350-HDS-010-SDS-010-SMS-050"
        && eastWestRealization.stage == "control-plane-model"
        && eastWestRealization.source == "inventory-realization"
        && eastWestRealization.selectedOverlayIdentity == "east-west"
        && eastWestRealization.participantLedger.source == "nfm-overlay-participant-ledger"
        && eastWestRealization.participantLedger.overlayIdentity == "east-west"
        && eastWestRealization.classification.kind == "overlay-participant-address"
        && eastWestRealization.classification.delegatedEndpointAuthority == false
        && eastWestRealization.classification.tenantPrefixAuthority == false
        && eastWestRealization.classification.providerPrefixAuthority == false
        && eastWestRealization.classification.forwardingAuthority == false
        && eastWestRealization.addresses.ipv4 == "100.64.10.1/32"
        && eastWestRealization.addresses.ipv6 == "fd42:dead:beef:10::1/128";

      providerLedgerStaysSeparate =
        providerRealization.selectedOverlayIdentity == "provider-egress"
        && providerRealization.participantLedger.overlayIdentity == "provider-egress"
        && providerRealization.addresses.ipv4 == "100.64.20.1/32"
        && providerRealization.classification.providerPrefixAuthority == false
        && providerRealization.classification.forwardingAuthority == false;

      hostOnlyProviderPrefixNotParticipantForwardingAuthority =
        hostOnlyEndpoint4
        && providerClassification.overlayClassification.clientPrefixAuthority.fromEndpointFacts == false
        && providerClassification.baseClassification.prefixAuthority.routedClient == false
        && providerClassification.baseClassification.prefixAuthority.delegated == false
        && providerClassification.baseClassification.routeAuthority.import == false
        && providerClassification.baseClassification.routeAuthority.export == false;
    };
  in
    if builtins.all (value: value == true) (builtins.attrValues checks) then
      true
    else
      throw ("fs350 inventory-realization cross-ledger checks failed: " + builtins.toJSON checks)
' >/dev/null

if REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    lib = import <nixpkgs/lib>;
    helpers = import (repoRoot + "/lib/contract.nix") { inherit lib; };
    ipam = import (repoRoot + "/src/cpm/ipam.nix") { inherit lib; };
    common = import (repoRoot + "/src/cpm/Site/build-data/common.nix") {
      inherit helpers ipam;
      enterpriseRoot = { };
    };
    badProvisioning =
      import (repoRoot + "/src/cpm/Site/build-data/overlay-provisioning.nix") {
        inherit lib helpers common ipam;
        allSiteEntries = [ ];
        enterpriseName = "acme";
        inventoryAttrs = { };
        sitePath = "forwardingModel.enterprise.acme.site.ams";
        siteAttrs = {
          overlayReachability.east-west = {
            overlay = "east-west";
            terminateOn = [ "edge" ];
          };
          overlayAddressPools.east-west = {
            ipv4.prefix = "100.64.10.0/24";
            ipv6.prefix = "fd42:dead:beef:10::/64";
          };
        };
        siteOverlays.east-west = {
          provider = "nebula";
          nodes.edge = {
            addr4 = "100.64.20.1/32";
            addr6 = "fd42:dead:beef:10::1/128";
          };
        };
      };
  in
    builtins.deepSeq badProvisioning.overlayProvisioning.east-west.nodes.edge true
' >/dev/null 2>"${tmp_dir}/wrong-ledger.err"; then
  echo "FAIL fs350-inventory-realization-cross-ledger-diagnostics: wrong-ledger realization was accepted" >&2
  exit 1
fi

grep -q "E_OVERLAY_PARTICIPANT_CROSS_LEDGER_REALIZATION" "${tmp_dir}/wrong-ledger.err"
grep -q "inventory-realization address '100.64.20.1/32'" "${tmp_dir}/wrong-ledger.err"
grep -q "selected overlay participant ledger 'east-west'" "${tmp_dir}/wrong-ledger.err"
grep -q "pool '100.64.10.0/24'" "${tmp_dir}/wrong-ledger.err"

echo "PASS fs350-inventory-realization-cross-ledger-diagnostics"
