#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-380-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-380-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-380-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    pkgs = import flake.inputs.nixpkgs { inherit system; };
    helpers = import ./src/cpm/cpm-contract-support.nix { inherit (pkgs) lib; };
    common = import ./src/cpm/Site/build-data/common.nix {
      inherit helpers;
      ipam = import ./src/cpm/ipam.nix { inherit (pkgs) lib; };
      enterpriseRoot = { };
    };
    ipv4InternetModeContract = import ./src/cpm/Site/build-data/ipv4-internet-mode.nix {
      inherit helpers common;
    };

    labs = flake.inputs.network-labs.outPath;
    baseIntent = import (labs + "/examples/single-wan/intent.nix");
    baseInventory = import (labs + "/examples/single-wan/inventory-clab.nix");

    publicClientPrefix = "198.51.100.0/24";
    hostOnlyAddress = "203.0.113.10/32";
    site = baseIntent.esp0xdeadbeef."site-a";
    hostUplink = baseInventory.deployment.hosts.lab-host.uplinks.uplink0;

    patchedSite = site // {
      ownership = site.ownership // {
        prefixes = map
          (prefix:
            if (prefix.name or null) == "client" then
              prefix // { ipv4 = publicClientPrefix; }
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
    inventory = baseInventory // {
      deployment = baseInventory.deployment // {
        hosts = baseInventory.deployment.hosts // {
          lab-host = baseInventory.deployment.hosts.lab-host // {
            uplinks = baseInventory.deployment.hosts.lab-host.uplinks // {
              uplink0 = hostUplink // {
                ipv4 = (hostUplink.ipv4 or { }) // {
                  address = hostOnlyAddress;
                  method = "static";
                };
              };
            };
          };
        };
      };
    };

    cpm = flake.lib.${system}.compileAndBuild {
      input = intent;
      inherit inventory;
    };
    siteOut = cpm.control_plane_model.data.esp0xdeadbeef."site-a";
    ipv4Modes = (siteOut.ipv4 or { }).internetModes or { };
    ipv4Diagnostics = (siteOut.ipv4 or { }).diagnostics or { };

    privateNatRecord =
      builtins.any
        (record:
          (record.mode or null) == "private-nat44"
          && (record.runtimeTarget or null) == "esp0xdeadbeef-site-a-s-router-core-wan"
          && (record.source or null) == "runtimeTargets.*.natIntent"
          && (record.sourcePrefixes or [ ]) == [ "10.20.10.0/24" "10.20.15.0/24" ]
          && (record.outputInterfaces or [ ]) == [ "ens4" ]
          && ((record.routeSafety or { }).sourceScopedTranslation or false) == true
          && ((record.routeSafety or { }).blackholed or false) == true)
        (ipv4Modes.privateNat44 or [ ]);

    routedPublicRecord =
      builtins.any
        (record:
          (record.mode or null) == "routed-public-ipv4"
          && (record.prefix or null) == publicClientPrefix
          && (record.tenant or null) == "client"
          && (record.owner or null) == "s-router-access-client"
          && (record.nat44 or true) == false
          && builtins.any
            (returnRoute:
              (returnRoute.runtimeTarget or null) == "esp0xdeadbeef-site-a-s-router-core-wan"
              && (returnRoute.interface or null) == "p2p-s-router-core-wan-s-router-upstream-selector"
              && (returnRoute.via4 or null) == "10.10.0.7")
            (record.returnRoutes or [ ]))
        (ipv4Modes.routedPublicIpv4 or [ ]);

    hostOnlyBoundaryRecord =
      builtins.any
        (record:
          (record.mode or null) == "host-only-ipv4-boundary"
          && (record.prefix or null) == hostOnlyAddress
          && (record.source or null) == "wan-realization"
          && (record.downstreamExport or true) == false
          && (record.tenantAuthority or true) == false
          && (record.nat44SourceAuthority or true) == false)
        (ipv4Modes.hostOnlyIpv4Boundary or [ ]);

    hostOnlyDiagnostic =
      builtins.any
        (diagnostic:
          (diagnostic.code or null) == "host-only-ipv4-downstream-export-denied"
          && (diagnostic.mode or null) == "fail-closed"
          && (diagnostic.prefix or null) == hostOnlyAddress
          && (diagnostic.downstreamExport or true) == false)
        (ipv4Diagnostics.hostOnlyIpv4Boundary or [ ]);

    noRoutedPublicDiagnostics = (ipv4Diagnostics.routedPublicIpv4 or [ ]) == [ ];

    missingReturn = ipv4InternetModeContract {
      tenantPrefixOwners = {
        "4|198.51.100.0/24" = {
          family = 4;
          dst = "198.51.100.0/24";
          netName = "client";
          owner = "access";
        };
      };
      runtimeTargets = {
        access.effectiveRuntimeRealization.interfaces.tenant = {
          logicalNode = "access";
          sourceKind = "tenant";
          tenant = "client";
          routes.ipv4 = [
            {
              dst = "198.51.100.0/24";
              proto = "connected";
              intent.kind = "connected-reachability";
            }
          ];
        };
      };
    };
    missingReturnDiagnostic =
      missingReturn.records.routedPublicIpv4 == [ ]
      && missingReturn.diagnostics.routedPublicIpv4 == [
        {
          code = "routed-public-ipv4-return-route-unavailable";
          mode = "fail-closed";
          prefix = "198.51.100.0/24";
          tenant = "client";
          owner = "access";
          message = "Routed public IPv4 mode requires an internal return route for the public client prefix.";
        }
      ];
  in
    if
      privateNatRecord
      && routedPublicRecord
      && hostOnlyBoundaryRecord
      && hostOnlyDiagnostic
      && noRoutedPublicDiagnostics
      && missingReturnDiagnostic
    then
      true
    else
      throw ("ipv4 internet mode contract failed: " + builtins.toJSON {
        inherit
          privateNatRecord
          routedPublicRecord
          hostOnlyBoundaryRecord
          hostOnlyDiagnostic
          noRoutedPublicDiagnostics
          missingReturnDiagnostic
          ;
        ipv4Modes = ipv4Modes;
        ipv4Diagnostics = ipv4Diagnostics;
        missingReturn = missingReturn;
      })
' >/dev/null

echo "PASS ipv4-internet-mode-contract"
