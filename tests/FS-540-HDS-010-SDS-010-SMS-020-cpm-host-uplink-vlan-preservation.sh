#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
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
    hostUplink = baseInventory.deployment.hosts.lab-host.uplinks.uplink0;
    inventory = baseInventory // {
      deployment = baseInventory.deployment // {
        hosts = baseInventory.deployment.hosts // {
          lab-host = baseInventory.deployment.hosts.lab-host // {
            uplinks = baseInventory.deployment.hosts.lab-host.uplinks // {
              uplink0 = hostUplink // {
                parent = "eth0";
                mode = "vlan";
                vlan = 4;
                ipv4 = (hostUplink.ipv4 or { }) // {
                  dhcp = true;
                  enable = true;
                  method = "dhcp";
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
    core = siteOut.runtimeTargets."esp0xdeadbeef-site-a-s-router-core-wan";
    wanHostUplink = core.effectiveRuntimeRealization.interfaces.wan.hostUplink;
    require = cond: msg: if cond then true else throw msg;
  in
    require (wanHostUplink.bridge == "br-uplink0")
      "CPM must preserve the WAN host uplink bridge"
    && require (wanHostUplink.parent == "eth0")
      "CPM must preserve the WAN host uplink parent"
    && require (wanHostUplink.mode == "vlan")
      "CPM must preserve VLAN link mode for renderer host-network materialization"
    && require (wanHostUplink.vlan == 4)
      "CPM must preserve VLAN ID for renderer host-network materialization"
    && require (wanHostUplink.ipv4.method == "dhcp")
      "CPM must keep DHCP as the IPv4 addressing method, not the link mode"
' >/dev/null

echo "PASS cpm-host-uplink-vlan-preservation"
