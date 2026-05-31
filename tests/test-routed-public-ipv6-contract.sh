#!/usr/bin/env bash
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-003-SMS-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-003-SMS-001-002
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-003-SMS-001-003
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-003-SMS-001-CMC-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-003-SMS-001-CMC-001-002
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-003-SMS-001-CMC-001-003
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
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
  in
    if hasAccessPrefix && hasCoreReturnRoute && nat66ExcludesPublicPrefix then
      true
    else
      throw ("routed public IPv6 contract failed: " + builtins.toJSON {
        inherit
          publicClientPrefix6
          canonicalClientPrefix6
          hasAccessPrefix
          hasCoreReturnRoute
          nat66ExcludesPublicPrefix
          ;
        accessClient = {
          addr6 = accessClient.addr6 or null;
          routes6 = accessRoutes6;
        };
        coreWanRoutes6 = coreWanRoutes6;
        natIntent = core.natIntent;
      })
' >/dev/null

echo "PASS routed-public-ipv6-contract"
