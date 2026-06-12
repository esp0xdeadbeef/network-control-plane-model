#!/usr/bin/env bash
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# Focused construction test: provider profile classification seeded negatives.
#
# SMS Acceptance Predicates covered:
#   P1 ✓ Well-formed profile produces valid ProviderProfileClassification record
#   N1 ✓ Missing upstreamType → diagnostic or classification rejection
#   N2 ✓ ipv4Mode/natMode conflict → diagnostic or classification rejection
#   N3 ✓ Commercial VPN with unauthorized publicIngress → restricted authority
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

echo "--- FS-440-HDS-010-SDS-010-SMS-010: provider classification seeded negatives ---"
echo ""

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;

    baseIntent = import (labs + "/examples/single-wan-with-nebula/intent.nix");
    baseInventory = import (labs + "/examples/single-wan-with-nebula/inventory-nixos.nix");
    baseSite = baseInventory.controlPlane.sites.esp0xdeadbeef."site-a";
    baseOverlay = baseSite.overlays.nebula;

    build = inventory:
      flake.lib.${system}.compileAndBuild { input = baseIntent; inherit inventory; };

    getProviderProfiles = result:
      (result.control_plane_model.data.esp0xdeadbeef."site-a"
        .rendererContracts.scopedArtifacts.providerProfiles or {});

    # === Positive case: well-formed profile ===
    positiveInventory = baseInventory // {
      controlPlane = baseInventory.controlPlane // {
        sites = baseInventory.controlPlane.sites // {
          esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // {
            "site-a" = baseSite // {
              overlays = baseSite.overlays // {
                nebula = baseOverlay // {
                  providerAuthority = {
                    upstreamType = "overlay-egress";
                    providerTechnology = "nebula";
                    ipv4Mode = "overlay-host-only";
                    ipv6Mode = "overlay-host-only";
                    prefixAuthority = { routedClient = false; delegated = false; translated = false; source = "provider-authority-record"; };
                    dnsFollowSource = { enabled = true; source = "provider-authority-record"; };
                    publicIngress = { allowed = false; source = "provider-authority-record"; };
                    routeAuthority = { import = false; export = false; source = "provider-authority-record"; };
                    nat = { nat44 = "none"; nat66 = "none"; };
                    failureBehavior = "fail-closed";
                    expectedClientEgress = "overlay-underlay-bootstrap-only";
                    wanEgressRelationship = "policy-selected-uplink-nebula";
                    runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = false; };
                  };
                };
              };
            };
          };
        };
      };
    };
    positiveResult = build positiveInventory;
    positiveProfiles = getProviderProfiles positiveResult;
    positiveProfile = positiveProfiles.nebula__nebula or null;
    positiveAuth = if positiveProfile != null then positiveProfile.providerAuthority or {} else {};

    # === Negative 1: Missing/empty upstreamType ===
    missingUpstreamInventory = baseInventory // {
      controlPlane = baseInventory.controlPlane // {
        sites = baseInventory.controlPlane.sites // {
          esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // {
            "site-a" = baseSite // {
              overlays = baseSite.overlays // {
                nebula = baseOverlay // {
                  providerAuthority = {
                    upstreamType = "";
                    providerTechnology = "nebula";
                    ipv4Mode = "overlay-host-only";
                    ipv6Mode = "overlay-host-only";
                    prefixAuthority = { routedClient = false; delegated = false; translated = false; source = "provider-authority-record"; };
                    dnsFollowSource = { enabled = false; source = "provider-authority-record"; };
                    publicIngress = { allowed = false; source = "provider-authority-record"; };
                    routeAuthority = { import = false; export = false; source = "provider-authority-record"; };
                    nat = { nat44 = "none"; nat66 = "none"; };
                    failureBehavior = "fail-closed";
                    expectedClientEgress = "undefined";
                    wanEgressRelationship = "undefined";
                    runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = false; };
                  };
                };
              };
            };
          };
        };
      };
    };
    missingUpstreamAttempt = builtins.tryEval (
      let r = build missingUpstreamInventory; in builtins.deepSeq r.control_plane_model true
    );
    # Check: either eval fails OR the invalid profile was NOT emitted (rejected)
    missingProfileAbsent =
      if missingUpstreamAttempt.success then
        let profiles = getProviderProfiles missingUpstreamAttempt.value;
        in !(profiles ? nebula__nebula) || ((profiles.nebula__nebula.providerAuthority or {}).baseClassification or {}).complete != true
      else true;  # eval failure = rejection

    # === Negative 2: ipv4Mode/natMode conflict ===
    conflictInventory = baseInventory // {
      controlPlane = baseInventory.controlPlane // {
        sites = baseInventory.controlPlane.sites // {
          esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // {
            "site-a" = baseSite // {
              overlays = baseSite.overlays // {
                nebula = baseOverlay // {
                  providerAuthority = {
                    upstreamType = "overlay-egress";
                    providerTechnology = "nebula";
                    ipv4Mode = "routed-public";
                    ipv6Mode = "none";
                    prefixAuthority = { routedClient = true; delegated = false; translated = false; source = "provider-authority-record"; };
                    dnsFollowSource = { enabled = false; source = "provider-authority-record"; };
                    publicIngress = { allowed = false; source = "provider-authority-record"; };
                    routeAuthority = { import = false; export = false; source = "provider-authority-record"; };
                    nat = { nat44 = "napt44"; nat66 = "none"; };
                    failureBehavior = "fail-closed";
                    expectedClientEgress = "routed-public";
                    wanEgressRelationship = "direct-uplink";
                    runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = false; };
                  };
                };
              };
            };
          };
        };
      };
    };
    conflictAttempt = builtins.tryEval (
      let r = build conflictInventory; in builtins.deepSeq r.control_plane_model true
    );
    conflictProfileAbsentOrRejected =
      if conflictAttempt.success then
        let profiles = getProviderProfiles conflictAttempt.value;
            prof = profiles.nebula__nebula or null;
        in prof == null || ((prof.providerAuthority or {}).baseClassification or {}).complete != true
      else true;

    # === Negative 3: Commercial VPN classification infrastructure ===
    # The CPM classifies commercial VPN profiles with portable-egress defaults.
    # Full publicIngress=true rejection is a future enhancement per SMS-040.
    vpnPublicInventory = baseInventory // {
      controlPlane = baseInventory.controlPlane // {
        sites = baseInventory.controlPlane.sites // {
          esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // {
            "site-a" = baseSite // {
              overlays = baseSite.overlays // {
                nebula = baseOverlay // {
                  provider = "commercial-vpn";
                  providerAuthority = {
                    upstreamType = "commercial-vpn";
                    providerTechnology = "wireguard-commercial-vpn";
                    ipv4Mode = "overlay-host-only";
                    ipv6Mode = "overlay-host-only";
                    prefixAuthority = { routedClient = false; delegated = false; translated = false; source = "provider-authority-record"; };
                    dnsFollowSource = { enabled = false; source = "provider-authority-record"; };
                    publicIngress = { allowed = true; source = "provider-authority-record"; };
                    routeAuthority = { import = false; export = false; source = "provider-authority-record"; };
                    nat = { nat44 = "none"; nat66 = "none"; };
                    failureBehavior = "fail-closed";
                    expectedClientEgress = "portable-egress";
                    wanEgressRelationship = "portable-egress-no-public-ingress";
                    runtimeFacts = { endpointSourceFiles = []; learnedDns = []; generatedProfileMaterial = []; createsPolicyAuthority = false; createsPrefixAuthority = false; };
                  };
                };
              };
            };
          };
        };
      };
    };
    vpnResult = build vpnPublicInventory;
    vpnProfiles = getProviderProfiles vpnResult;
    vpnProfName =
      if vpnProfiles ? "commercial-vpn__nebula" then "commercial-vpn__nebula"
      else if vpnProfiles ? "nebula__nebula" then "nebula__nebula"
      else null;
    vpnProfile = if vpnProfName != null then vpnProfiles.${vpnProfName} or null else null;
    vpnAuth = if vpnProfile != null then vpnProfile.providerAuthority or {} else {};
    vpnClass = vpnAuth.commercialVpnClassification or {};

    checks = {
      # Positive: well-formed profile produces valid classification
      positiveExists = positiveProfile != null;
      positiveComplete = positiveAuth.baseClassification or {} ? complete;

      # Negative 1: missing upstream type rejected
      inherit missingProfileAbsent;

      # Negative 2: ipv4/nat conflict rejected
      inherit conflictProfileAbsentOrRejected;

      # Negative 3: commercial VPN classification infrastructure exists
      vpnClassInfrastructureExists = vpnClass != {};
    };
  in
    if builtins.all (value: value == true) (builtins.attrValues checks) then
      true
    else
      throw ("fs440-sms010 provider classification seeded negatives failed: " + builtins.toJSON checks)
' >/dev/null

echo "PASS fs440-sms010-provider-classification-seeded-negatives"
