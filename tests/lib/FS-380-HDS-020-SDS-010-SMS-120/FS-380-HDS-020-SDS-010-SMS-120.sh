#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-120
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

NETWORK_LABS_PATH="${NETWORK_LABS_PATH:-${repo_root}/../network-labs}" \
REPO_ROOT="${repo_root}" \
nix eval --impure --expr '
  let
    traceId = "FS-380-HDS-020-SDS-010-SMS-120";
    repoRoot = builtins.getEnv "REPO_ROOT";
    labsPathEnv = builtins.getEnv "NETWORK_LABS_PATH";
    flake = builtins.getFlake ("path:" + repoRoot);
    system = builtins.currentSystem;
    labs =
      if labsPathEnv != "" then
        labsPathEnv
      else
        flake.inputs.network-labs.outPath;

    metadata = import (labs + "/current-lab/metadata.nix");
    input = import (labs + "/current-lab/intent-s-router-nixos.nix");
    baseInventory = import (labs + "/current-lab/inventory-s-router-nixos.nix");

    accessNodeKey = "mini-smt-${traceId}-access-vlan2";
    accessNode = baseInventory.realization.nodes.${accessNodeKey};
    p2pIfName = "p2p-access-vlan2-downstream-selector";
    tenantIfName = "tenant-client";
    p2pPort = accessNode.ports.${p2pIfName};
    tenantPort = accessNode.ports.${tenantIfName};

    # Seed the prod-like ordering that used to break route policy semantics:
    # access-edge p2p runtime name sorts before tenant runtime name.
    inventory =
      baseInventory
      // {
        realization =
          baseInventory.realization
          // {
            nodes =
              baseInventory.realization.nodes
              // {
                ${accessNodeKey} =
                  accessNode
                  // {
                    ports =
                      accessNode.ports
                      // {
                        ${p2pIfName} =
                          p2pPort
                          // {
                            interface = (p2pPort.interface or { }) // {
                              name = "access-vlan2";
                            };
                          };
                        ${tenantIfName} =
                          tenantPort
                          // {
                            interface = (tenantPort.interface or { }) // {
                              name = "lan2";
                            };
                          };
                      };
                  };
              };
          };
      };

    out = flake.lib.${system}.compileAndBuild {
      inherit input inventory;
    };
    site = out.control_plane_model.data.mini-smt.${traceId};
    accessTarget = site.runtimeTargets.${accessNodeKey};
    interfaces = accessTarget.effectiveRuntimeRealization.interfaces;
    p2pIface = interfaces.${p2pIfName};
    tenantIface = interfaces.${tenantIfName};
    p2pAllocation = p2pIface.policyRoutingAllocation;
    tenantAllocation = tenantIface.policyRoutingAllocation;

    require = cond: msg: if cond then true else throw msg;
  in
    require ((metadata.traceId or "") == traceId)
      "${traceId}: current-lab selector must point at the prod-like IPv4 SMS"
    && require ((tenantIface.sourceKind or null) == "tenant")
      "${traceId}: access tenant interface must carry explicit tenant sourceKind"
    && require ((p2pIface.sourceKind or null) == "p2p")
      "${traceId}: access-edge interface must carry explicit p2p sourceKind"
    && require (((p2pIface.backingRef or { }).lane or { }).kind == "access-edge")
      "${traceId}: access-edge p2p must carry lane.kind=access-edge"
    && require ((tenantIface.runtimeIfName or null) == "lan2")
      "${traceId}: seeded tenant runtime name must be lan2"
    && require ((p2pIface.runtimeIfName or null) == "access-vlan2")
      "${traceId}: seeded p2p runtime name must be access-vlan2"
    && require ((tenantAllocation.source or null) == "control-plane-model")
      "${traceId}: tenant policy allocation must originate in CPM"
    && require ((p2pAllocation.source or null) == "control-plane-model")
      "${traceId}: p2p policy allocation must originate in CPM"
    && require ((tenantAllocation.allocation or null) == "semantic-interface-class-slot")
      "${traceId}: tenant policy allocation must use semantic interface class ordering"
    && require ((p2pAllocation.allocation or null) == "semantic-interface-class-slot")
      "${traceId}: p2p policy allocation must use semantic interface class ordering"
    && require ((tenantAllocation.tableId or null) == 1001)
      "${traceId}: tenant return table must remain 1001 even when p2p runtime name sorts first"
    && require ((p2pAllocation.tableId or null) == 1002)
      "${traceId}: access-edge egress table must remain 1002 even when p2p runtime name sorts first"
    && require ((tenantAllocation.tableRulePriority or null) < (p2pAllocation.tableRulePriority or null))
      "${traceId}: tenant return rule priority must sort before access-edge egress priority"
    && require ((tenantAllocation.mainSuppressPriority or null) < (p2pAllocation.mainSuppressPriority or null))
      "${traceId}: tenant main suppress priority must sort before access-edge egress suppress priority"
' >/dev/null

echo "PASS FS-380-HDS-020-SDS-010-SMS-120 access policy allocation"
