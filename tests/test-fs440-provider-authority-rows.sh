#!/usr/bin/env bash
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-040
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;

    baseIntent = import (labs + "/examples/single-wan-with-nebula/intent.nix");
    baseInventory = import (labs + "/examples/single-wan-with-nebula/inventory-nixos.nix");
    baseSite = baseInventory.controlPlane.sites.esp0xdeadbeef."site-a";
    baseOverlay = baseSite.overlays.nebula;

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
        enabled = true;
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
      wanEgressRelationship = "policy-selected-uplink-nebula";
      runtimeFacts = {
        endpointSourceFiles = [
          "/run/secrets/nebula-public-ipv4"
          "/run/secrets/nebula-public-ipv6"
        ];
        learnedDns = [ "192.0.2.53" "2001:db8::53" ];
        generatedProfileMaterial = [ "nebula lighthouse endpoint" ];
        createsPolicyAuthority = false;
        createsPrefixAuthority = false;
      };
    };

    focusedInventory = baseInventory // {
      controlPlane = baseInventory.controlPlane // {
        sites = baseInventory.controlPlane.sites // {
          esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // {
            "site-a" = baseSite // {
              overlays = baseSite.overlays // {
                nebula = baseOverlay // {
                  inherit providerAuthority;
                };
              };
            };
          };
        };
      };
    };

    commercialInventory = baseInventory // {
      controlPlane = baseInventory.controlPlane // {
        sites = baseInventory.controlPlane.sites // {
          esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // {
            "site-a" = baseSite // {
              overlays = baseSite.overlays // {
                nebula = baseOverlay // {
                  provider = "commercial-vpn";
                  providerAuthority = providerAuthority // {
                    upstreamType = "commercial-vpn";
                    providerTechnology = "wireguard-commercial-vpn";
                    expectedClientEgress = "portable-egress";
                    wanEgressRelationship = "portable-egress-no-public-ingress";
                  };
                };
              };
            };
          };
        };
      };
    };

    badRuntimeAuthorityInventory = baseInventory // {
      controlPlane = baseInventory.controlPlane // {
        sites = baseInventory.controlPlane.sites // {
          esp0xdeadbeef = baseInventory.controlPlane.sites.esp0xdeadbeef // {
            "site-a" = baseSite // {
              overlays = baseSite.overlays // {
                nebula = baseOverlay // {
                  providerAuthority = providerAuthority // {
                    runtimeFacts = providerAuthority.runtimeFacts // {
                      createsPolicyAuthority = true;
                    };
                  };
                };
              };
            };
          };
        };
      };
    };

    focused = flake.lib.${system}.compileAndBuild {
      input = baseIntent;
      inventory = focusedInventory;
    };
    commercial = flake.lib.${system}.compileAndBuild {
      input = baseIntent;
      inventory = commercialInventory;
    };

    provider =
      focused.control_plane_model.data.esp0xdeadbeef."site-a"
        .rendererContracts.scopedArtifacts.providerProfiles.nebula__nebula;
    authority = provider.providerAuthority;
    commercialProvider =
      commercial.control_plane_model.data.esp0xdeadbeef."site-a"
        .rendererContracts.scopedArtifacts.providerProfiles.commercial-vpn__nebula;
    commercialAuthority = commercialProvider.providerAuthority;

    badRuntimeAttempt =
      builtins.tryEval (
        let
          bad = flake.lib.${system}.compileAndBuild {
            input = baseIntent;
            inventory = badRuntimeAuthorityInventory;
          };
          badAuthority =
            bad.control_plane_model.data.esp0xdeadbeef."site-a"
              .rendererContracts.scopedArtifacts.providerProfiles.nebula__nebula.providerAuthority;
        in
        builtins.deepSeq badAuthority true
      );

    hasRow = row: builtins.elem row authority.rowIds;
    endpoint4 =
      builtins.any
        (record:
          record.family == 4
          && record.address == "100.96.10.1/32"
          && record.classification == "host-only-provider-endpoint"
          && record.hostOnly == true
          && record.clientPrefixAuthority == false)
        authority.endpointClassification.records;
    endpoint6 =
      builtins.any
        (record:
          record.family == 6
          && record.address == "fd42:dead:beef:ee::1/128"
          && record.classification == "host-only-provider-endpoint"
          && record.hostOnly == true
          && record.clientPrefixAuthority == false)
        authority.endpointClassification.records;

    checks = {
      sms010_base_profile_one_to_one =
        hasRow "FS-440-HDS-010-SDS-010-SMS-010"
        && authority.emittedRecord.kind == "provider-authority-classification"
        && authority.consumedInterfaces.providerDeclaration == "controlPlane.sites.*.*.overlays.nebula.provider"
        && authority.baseClassification.upstreamType == "overlay-egress"
        && authority.baseClassification.ipv4Mode == "overlay-host-only"
        && authority.baseClassification.ipv6Mode == "overlay-host-only"
        && authority.baseClassification.prefixAuthority.routedClient == false
        && authority.baseClassification.prefixAuthority.delegated == false
        && authority.baseClassification.prefixAuthority.translated == false
        && authority.baseClassification.dnsFollowSource.enabled == true
        && authority.baseClassification.publicIngress.allowed == false
        && authority.baseClassification.routeAuthority.import == false
        && authority.baseClassification.routeAuthority.export == false
        && authority.baseClassification.nat.nat44 == "none"
        && authority.baseClassification.nat.nat66 == "none"
        && authority.baseClassification.failureBehavior == "fail-closed"
        && authority.baseClassification.expectedClientEgress == "overlay-underlay-bootstrap-only"
        && authority.baseClassification.complete == true
        && authority.baseClassification.behaviorEmissionAllowed == true
        && authority.diagnostics.baseClassification == [ ];

      sms020_overlay_identity_ipam_wan_egress =
        hasRow "FS-440-HDS-010-SDS-010-SMS-020"
        && provider.scope.kind == "providerProfile"
        && provider.scope.provider == "nebula"
        && provider.scope.overlay == "nebula"
        && authority.overlayClassification.overlayIdentity == "nebula"
        && authority.overlayClassification.providerTechnology == "nebula"
        && authority.overlayClassification.overlayNodeIpamAuthority.ipv4.prefix == "100.96.10.0/24"
        && authority.overlayClassification.overlayNodeIpamAuthority.ipv4.perNodePrefixLength == 32
        && authority.overlayClassification.overlayNodeIpamAuthority.ipv6.prefix == "fd42:dead:beef:ee::/64"
        && authority.overlayClassification.overlayNodeIpamAuthority.ipv6.perNodePrefixLength == 128
        && authority.overlayClassification.overlayNodeIpamAuthority.nodes.s-router-core-nebula.addr4 == "100.96.10.1/32"
        && authority.overlayClassification.overlayNodeIpamAuthority.nodes.s-router-core-nebula.addr6 == "fd42:dead:beef:ee::1/128"
        && authority.overlayClassification.clientPrefixAuthority.fromEndpointFacts == false
        && authority.overlayClassification.wanEgressRelationship == "policy-selected-uplink-nebula";

      sms030_host_only_ipv4_and_ipv6 =
        hasRow "FS-440-HDS-010-SDS-010-SMS-030"
        && endpoint4
        && endpoint6
        && authority.endpointClassification.invalidEndpointPromotion == false;

      sms040_commercial_vpn_portable_default =
        hasRow "FS-440-HDS-010-SDS-010-SMS-040"
        && commercialProvider.scope.provider == "commercial-vpn"
        && commercialAuthority.commercialVpnClassification.applies == true
        && commercialAuthority.commercialVpnClassification.default == "portable-egress"
        && commercialAuthority.commercialVpnClassification.publicIngressAllowed == false
        && commercialAuthority.commercialVpnClassification.routedClientPrefixAllowed == false
        && commercialAuthority.commercialVpnClassification.grantsAuthorityFromPresence == false
        && commercialAuthority.baseClassification.expectedClientEgress == "portable-egress";

      sms050_runtime_fact_record_and_authority_diagnostic =
        hasRow "FS-440-HDS-010-SDS-010-SMS-050"
        && authority.runtimeFactSeparation.records == [
          {
            kind = "provider-runtime-facts";
            source = "providerAuthority.runtimeFacts";
            facts = {
              endpointSourceFiles = [
                "/run/secrets/nebula-public-ipv4"
                "/run/secrets/nebula-public-ipv6"
              ];
              learnedDns = [ "192.0.2.53" "2001:db8::53" ];
              generatedProfileMaterial = [ "nebula lighthouse endpoint" ];
            };
            authority = {
              createsPolicyAuthority = false;
              createsPrefixAuthority = false;
              runtimeAuthority = false;
            };
          }
        ]
        && authority.runtimeFactSeparation.diagnostic.code == "provider-runtime-facts-not-authority"
        && authority.runtimeFactSeparation.diagnostic.mode == "fail-closed"
        && authority.runtimeFactSeparation.diagnostic.runtimeAuthority == false
        && authority.runtimeFactSeparation.diagnostic.policyAuthority == false
        && authority.runtimeFactSeparation.diagnostic.prefixAuthority == false
        && badRuntimeAttempt.success == false;
    };
  in
    if builtins.all (value: value == true) (builtins.attrValues checks) then
      true
    else
      throw ("fs440 provider authority row checks failed: " + builtins.toJSON {
        failed = builtins.filter (name: checks.${name} != true) (builtins.attrNames checks);
        inherit checks authority commercialAuthority;
        badRuntimeAttempt = badRuntimeAttempt;
      })
' >/dev/null

echo "PASS fs440-provider-authority-rows"
