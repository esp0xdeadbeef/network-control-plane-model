#!/usr/bin/env bash
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-002-SMS-001-001
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-002-SMS-001-002
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-002-SMS-001-003
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-001
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-002
# GAMP-ID: USR-INET-001-FS-001-HDS-001-SDS-001-002-SMS-001-CMC-001-003
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
    publicClientPrefix = "198.51.100.0/24";
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

    cpm = flake.lib.${system}.compileAndBuild {
      input = intent;
      inherit inventory;
    };
    siteOut = cpm.control_plane_model.data.esp0xdeadbeef."site-a";
    core = siteOut.runtimeTargets."esp0xdeadbeef-site-a-s-router-core-wan";
    access = siteOut.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    accessClient = access.effectiveRuntimeRealization.interfaces."tenant-client";
    coreWanRoutes =
      core.effectiveRuntimeRealization.interfaces."p2p-s-router-core-wan-s-router-upstream-selector"
        .routes.ipv4 or [ ];

    hasAccessPrefix =
      (accessClient.addr4 or null) == "198.51.100.1/24"
      && builtins.any
        (route:
          (route.dst or null) == publicClientPrefix
          && ((route.intent or { }).kind or null) == "connected-reachability")
        ((accessClient.routes or { }).ipv4 or [ ]);

    hasCoreReturnRoute =
      builtins.any
        (route:
          (route.dst or null) == publicClientPrefix
          && (route.via4 or null) == "10.10.0.7"
          && ((route.intent or { }).kind or null) == "internal-reachability")
        coreWanRoutes;

    natScopeExcludesPublicPrefix =
      !(builtins.elem publicClientPrefix (core.natIntent.masqueradeSourcePrefixes4 or [ ]));
  in
    if hasAccessPrefix && hasCoreReturnRoute && natScopeExcludesPublicPrefix then
      true
    else
      throw ("routed public IPv4 contract failed: " + builtins.toJSON {
        inherit
          publicClientPrefix
          hasAccessPrefix
          hasCoreReturnRoute
          natScopeExcludesPublicPrefix
          ;
        accessClient = {
          addr4 = accessClient.addr4 or null;
          routes4 = (accessClient.routes or { }).ipv4 or [ ];
        };
        coreWanRoutes = coreWanRoutes;
        natSourcePrefixes4 = core.natIntent.masqueradeSourcePrefixes4 or [ ];
      })
' >/dev/null

echo "PASS routed-public-ipv4-contract"
