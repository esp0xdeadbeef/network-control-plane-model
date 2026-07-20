#!/usr/bin/env bash
# GAMP-ID: FS-400-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-410-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    pkgs = import flake.inputs.nixpkgs { inherit system; };
    labs = flake.inputs.network-labs.outPath;
    baseIntent = import (labs + "/examples/single-wan/intent.nix");
    inventory = import (labs + "/examples/single-wan/inventory-clab.nix");

    site = baseIntent.esp0xdeadbeef."site-a";
    publicClientPrefix6 = "2001:db8:20::/64";
    canonicalClientPrefix6 = "2001:0db8:0020:0000:0000:0000:0000:0000/64";
    patchedSite = site // {
      ownership = site.ownership // {
        prefixes = map
          (prefix:
            if (prefix.name or null) == "client" then
              prefix // { ipv6 = publicClientPrefix6; }
            else
              prefix)
          site.ownership.prefixes;
      };
    };
    intent = baseIntent // {
      esp0xdeadbeef = baseIntent.esp0xdeadbeef // {
        "site-a" = patchedSite;
      };
    };

    cpm = flake.lib.${system}.compileAndBuild {
      input = intent;
      inherit inventory;
    };
    siteOut = cpm.control_plane_model.data.esp0xdeadbeef."site-a";
    core = siteOut.runtimeTargets."esp0xdeadbeef-site-a-s-router-core-wan";
    access = siteOut.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    accessClient = access.effectiveRuntimeRealization.interfaces."tenant-client";
    accessRoutes6 = (accessClient.routes or { }).ipv6 or [ ];
    coreWanRoutes6 =
      core.effectiveRuntimeRealization.interfaces."p2p-s-router-core-wan-s-router-upstream-selector"
        .routes.ipv6 or [ ];

    hasAccessPrefix =
      (accessClient.addr6 or null) == "2001:db8:20:0:0:0:0:1/64"
      && builtins.any
        (route:
          (route.dst or null) == canonicalClientPrefix6
          && ((route.intent or { }).kind or null) == "connected-reachability")
        accessRoutes6;

    hasCoreReturnRoute =
      builtins.any
        (route:
          (route.dst or null) == canonicalClientPrefix6
          && (route.via6 or null) == "fd42:dead:beef:1000:0:0:0:7"
          && ((route.intent or { }).kind or null) == "internal-reachability")
        coreWanRoutes6;

    nat66ExcludesPublicPrefix =
      (core.natIntent.families.ipv6 or false) == false
      && !(builtins.elem canonicalClientPrefix6 (core.natIntent.masqueradeSourcePrefixes6 or [ ]))
      && !(builtins.elem publicClientPrefix6 (core.natIntent.masqueradeSourcePrefixes6 or [ ]));

    routedGuaMode =
      (siteOut.ipv6 or { }).internetModes.routedClientGua or [ ];
    routedGuaDiagnostics =
      (siteOut.ipv6 or { }).diagnostics.routedClientGua or [ ];
    routedGuaModeRecord =
      builtins.any
        (record:
          (record.mode or null) == "routed-client-gua"
          && (record.prefix or null) == canonicalClientPrefix6
          && (record.tenant or null) == "client"
          && (record.owner or null) == "s-router-access-client"
          && builtins.any
            (returnRoute:
              (returnRoute.runtimeTarget or null) == "esp0xdeadbeef-site-a-s-router-core-wan"
              && (returnRoute.interface or null) == "p2p-s-router-core-wan-s-router-upstream-selector"
              && (returnRoute.via6 or null) == "fd42:dead:beef:1000:0:0:0:7")
            (record.returnRoutes or [ ]))
        routedGuaMode;
    routedGuaHasNoDiagnostic = routedGuaDiagnostics == [ ];

    routedGuaContract = import ./src/cpm/Site/build-data/routed-client-gua-mode.nix {
      helpers = import ./src/cpm/cpm-contract-support.nix { inherit (pkgs) lib; };
      common = import ./src/cpm/Site/build-data/common.nix {
        helpers = import ./src/cpm/cpm-contract-support.nix { inherit (pkgs) lib; };
        ipam = import ./src/cpm/ipam.nix { inherit (pkgs) lib; };
        enterpriseRoot = { };
      };
    };
    diagnosticRuntimeTargets = {
      access = {
        effectiveRuntimeRealization.interfaces.tenant = {
          logicalNode = "access";
          sourceKind = "tenant";
          tenant = "client";
          routes.ipv6 = [
            {
              dst = canonicalClientPrefix6;
              proto = "connected";
              intent.kind = "connected-reachability";
            }
          ];
        };
      };
      core = {
        effectiveRuntimeRealization.interfaces.wan.routes.ipv6 = [
          {
            dst = canonicalClientPrefix6;
            proto = "internal";
            via6 = "fd42:dead:beef:1000:0:0:0:7";
            intent.kind = "internal-reachability";
          }
        ];
      };
    };
    missingAuthority = routedGuaContract {
      tenantPrefixOwners = { };
      runtimeTargets = diagnosticRuntimeTargets;
    };
    missingReturnRoute = routedGuaContract {
      tenantPrefixOwners = {
        "6|${canonicalClientPrefix6}" = {
          family = 6;
          dst = canonicalClientPrefix6;
          netName = "client";
          owner = "access";
        };
      };
      runtimeTargets = {
        access = diagnosticRuntimeTargets.access;
      };
    };
    missingAuthorityDiagnostic =
      missingAuthority.records == [ ]
      && missingAuthority.diagnostics == [
        {
          code = "routed-gua-authority-unavailable";
          mode = "fail-closed";
          prefix = canonicalClientPrefix6;
          accessNodes = [ "access" ];
          message = "Routed client GUA mode observed a connected GUA prefix without explicit tenant prefix authority.";
        }
      ];
    missingReturnRouteDiagnostic =
      missingReturnRoute.records == [ ]
      && missingReturnRoute.diagnostics == [
        {
          code = "routed-gua-return-route-unavailable";
          mode = "fail-closed";
          prefix = canonicalClientPrefix6;
          tenant = "client";
          owner = "access";
          message = "Routed client GUA mode requires an internal IPv6 return route for the client GUA prefix.";
        }
      ];
  in
    if
      hasAccessPrefix
      && hasCoreReturnRoute
      && nat66ExcludesPublicPrefix
      && routedGuaModeRecord
      && routedGuaHasNoDiagnostic
      && missingAuthorityDiagnostic
      && missingReturnRouteDiagnostic
    then
      true
    else
      throw ("routed public IPv6 contract failed: " + builtins.toJSON {
        inherit
          publicClientPrefix6
          canonicalClientPrefix6
          hasAccessPrefix
          hasCoreReturnRoute
          nat66ExcludesPublicPrefix
          routedGuaModeRecord
          routedGuaHasNoDiagnostic
          missingAuthorityDiagnostic
          missingReturnRouteDiagnostic
          ;
        accessClient = {
          addr6 = accessClient.addr6 or null;
          routes6 = accessRoutes6;
        };
        coreWanRoutes6 = coreWanRoutes6;
        natIntent = core.natIntent;
        routedGuaMode = routedGuaMode;
        routedGuaDiagnostics = routedGuaDiagnostics;
        missingAuthority = missingAuthority;
        missingReturnRoute = missingReturnRoute;
      })
' >/dev/null

echo "PASS routed-public-ipv6-contract"
