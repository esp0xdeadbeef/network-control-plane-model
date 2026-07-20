#!/usr/bin/env bash
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
# Purpose: Focused construction test for overlay provider profile classification,
#          including both seeded negatives from SMS-020.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    # Minimal stubs for helpers and common
    helpers = {
      isNonEmptyString = x: builtins.isString x && x != "";
      hasAttr = builtins.hasAttr;
      sortedNames = xs: builtins.sort (a: b: a < b) (builtins.attrNames xs);
    };
    common = {
      attrsOrEmpty = x: if builtins.isAttrs x then x else { };
      listOrEmpty = x: if builtins.isList x then x else [ ];
      failInventory = path: message: throw "inventory.nix update required: ${path}: ${message}";
    };

    classifyModule = import (builtins.getEnv "REPO_ROOT" + "/src/cpm/Site/build-data/provider-authority-classification.nix") {
      inherit helpers common;
    };
    classify = classifyModule.classify;

    # --- Positive case ---
    positiveOverlay = {
      provider = "nebula";
      providerAuthority = {
        upstreamType = "overlay-egress";
        providerTechnology = "nebula";
        ipv4Mode = "overlay-host-only";
        ipv6Mode = "overlay-host-only";
        prefixAuthority = {
          routedClient = false;
          delegated = false;
          translated = false;
          source = "test";
        };
        dnsFollowSource = {
          enabled = true;
          source = "test";
        };
        publicIngress = {
          allowed = false;
          source = "test";
        };
        routeAuthority = {
          import = false;
          export = false;
          source = "test";
        };
        nat = {
          nat44 = "none";
          nat66 = "none";
        };
        failureBehavior = "fail-closed";
        expectedClientEgress = "overlay-underlay-bootstrap-only";
        wanEgressRelationship = "policy-selected-uplink-nebula";
      };
      ipam = {
        ipv4 = { prefix = "100.96.10.0/24"; perNodePrefixLength = 32; };
        ipv6 = { prefix = "fd42:dead:beef:ee::/64"; perNodePrefixLength = 128; };
      };
      nodes = {
        s-router-core-nebula = {
          addr4 = "100.96.10.1/32";
          addr6 = "fd42:dead:beef:ee::1/128";
        };
      };
    };

    positive = classify {
      overlayName = "nebula";
      overlay = positiveOverlay;
    };

    pos_checks = {
      overlayIdentity =
        positive.overlayClassification.overlayIdentity == "nebula";
      providerTechnology =
        positive.overlayClassification.providerTechnology == "nebula";
      ipamAuthority_ipv4 =
        positive.overlayClassification.overlayNodeIpamAuthority.ipv4.prefix
        == "100.96.10.0/24";
      ipamAuthority_ipv6 =
        positive.overlayClassification.overlayNodeIpamAuthority.ipv6.prefix
        == "fd42:dead:beef:ee::/64";
      clientPrefix_fromEndpointFacts =
        positive.overlayClassification.clientPrefixAuthority.fromEndpointFacts
        == false;
      wanEgressRelationship =
        positive.overlayClassification.wanEgressRelationship
        == "policy-selected-uplink-nebula";
      hasRowId =
        builtins.elem "FS-440-HDS-010-SDS-010-SMS-020" positive.rowIds;
    };

    # --- Seeded Negative 1: Missing overlay identity ---
    sn1_throws =
      builtins.tryEval (
        classify {
          overlayName = "";
          overlay = positiveOverlay;
        }
      );

    # --- Seeded Negative 2: Borrowed unrelated overlay node pool ---
    # Inject a profile where authority.overlayIdentity does not match overlayName
    badPoolOverlay = positiveOverlay // {
      providerAuthority = positiveOverlay.providerAuthority // {
        overlayIdentity = "wireguard";   # does not match overlayName="nebula"
      };
    };

    sn2_throws =
      builtins.tryEval (
        classify {
          overlayName = "nebula";
          overlay = badPoolOverlay;
        }
      );

    checks = pos_checks // {
      sn1_missing_overlay_identity_fail_closed = sn1_throws.success == false;
      sn2_borrowed_unrelated_pool_fail_closed = sn2_throws.success == false;
    };
  in
    if builtins.all (value: value == true) (builtins.attrValues checks) then
      true
    else
      throw ("FS-440-HDS-010-SDS-010-SMS-020 overlay provider profile classification checks failed: " + builtins.toJSON {
        failed = builtins.filter (name: checks.${name} != true) (builtins.attrNames checks);
        inherit checks;
        sn1_throws = sn1_throws;
        sn2_throws = sn2_throws;
      })
' >/dev/null

echo "PASS FS-440-HDS-010-SDS-010-SMS-020-overlay-provider-profile-classification"
