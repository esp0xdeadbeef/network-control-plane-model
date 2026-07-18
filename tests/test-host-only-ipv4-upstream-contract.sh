#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    labs = flake.inputs.network-labs.outPath;
    intent = import (labs + "/examples/single-wan/intent.nix");
    baseInventory = import (labs + "/examples/single-wan/inventory-clab.nix");
    hostOnlyAddress = "203.0.113.10/32";
    hostUplink = baseInventory.deployment.hosts.lab-host.uplinks.uplink0;
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
    runtimeTargets = siteOut.runtimeTargets;
    core = runtimeTargets."esp0xdeadbeef-site-a-s-router-core-wan";
    interfaces =
      builtins.concatLists (
        builtins.map
          (targetName:
            builtins.attrValues (
              runtimeTargets.${targetName}.effectiveRuntimeRealization.interfaces or { }
            ))
          (builtins.attrNames runtimeTargets)
      );
    tenantInterfaces = builtins.filter (iface: (iface.sourceKind or null) == "tenant") interfaces;
    tenantOwnsHostAddress =
      builtins.any
        (iface:
          (iface.addr4 or null) == hostOnlyAddress
          || builtins.any
            (route: (route.dst or null) == hostOnlyAddress)
            (((iface.routes or { }).ipv4 or [ ])))
        tenantInterfaces;
    anyReturnRouteForHostAddress =
      builtins.any
        (iface:
          builtins.any
            (route: (route.dst or null) == hostOnlyAddress)
            (((iface.routes or { }).ipv4 or [ ])))
        interfaces;
    natScopeContainsHostAddress =
      builtins.elem hostOnlyAddress (core.natIntent.masqueradeSourcePrefixes4 or [ ]);
  in
    if !tenantOwnsHostAddress && !anyReturnRouteForHostAddress && !natScopeContainsHostAddress then
      true
    else
      throw ("host-only IPv4 upstream contract failed: " + builtins.toJSON {
        inherit
          hostOnlyAddress
          tenantOwnsHostAddress
          anyReturnRouteForHostAddress
          natScopeContainsHostAddress
          ;
        natSourcePrefixes4 = core.natIntent.masqueradeSourcePrefixes4 or [ ];
      })
' >/dev/null

echo "PASS host-only-ipv4-upstream-contract"
