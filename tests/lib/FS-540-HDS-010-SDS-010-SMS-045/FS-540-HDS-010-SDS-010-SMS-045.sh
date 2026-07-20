#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-045
# GAMP-SCOPE: controlled iterative authority realization contract
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
cd "${repo_root}"

nix eval --impure --expr '
let
  flake = builtins.getFlake (toString ./.);
  system = builtins.currentSystem;
  labs = /home/deadbeef/github/network-labs;
  trace = "FS-540-HDS-010-SDS-010-SMS-045";
  row = labs + "/GAMP/SMT/${trace}";
  source = import (row + "/intent.nix");
  nixosInventory = import (row + "/inventory-nixos.nix");
  clabInventory = import (row + "/inventory-clab.nix");
  build = inventory: flake.libBySystem.${system}.compileAndBuild {
    input = source;
    inherit inventory;
  };
  authorityFor = built:
    let
      targets = built.control_plane_model.data."mini-smt".${trace}.runtimeTargets;
      core = builtins.head (builtins.filter
        (target: target.logicalNode.name == "core-primary")
        (builtins.attrValues targets));
    in
      core.services.dns.validationAuthority;
  sourceAuthority = inventory:
    (builtins.head (builtins.filter
      (node: (node.logicalNode.name or null) == "core-primary")
      (builtins.attrValues inventory.realization.nodes))).services.dns.validationAuthority;
  coreName = builtins.head (builtins.filter
    (name: nixosInventory.realization.nodes.${name}.logicalNode.name == "core-primary")
    (builtins.attrNames nixosInventory.realization.nodes));
  mutateAuthority = f:
    nixosInventory // {
      realization = nixosInventory.realization // {
        nodes = nixosInventory.realization.nodes // {
          ${coreName} =
            let node = nixosInventory.realization.nodes.${coreName};
            in node // {
              services = node.services // {
                dns = node.services.dns // {
                  validationAuthority = f node.services.dns.validationAuthority;
                };
              };
            };
        };
      };
    };
  nixosBuilt = build nixosInventory;
  clabBuilt = build clabInventory;
  nixosAuthority = authorityFor nixosBuilt;
  clabAuthority = authorityFor clabBuilt;
  nixosComplete = builtins.tryEval (builtins.deepSeq nixosBuilt.control_plane_model true);
  clabComplete = builtins.tryEval (builtins.deepSeq clabBuilt.control_plane_model true);
  badScope = builtins.tryEval (builtins.deepSeq
    (build (mutateAuthority (authority: authority // { scope = "production"; })))
    true);
  badSelection = builtins.tryEval (builtins.deepSeq
    (build (mutateAuthority (authority: authority // {
      alternateUplinks = [ authority.selectedUplink ];
    })))
    true);
in
  assert nixosAuthority == sourceAuthority nixosInventory;
  assert clabAuthority == sourceAuthority clabInventory;
  assert nixosComplete.success;
  assert clabComplete.success;
  assert nixosAuthority == clabAuthority;
  assert nixosAuthority.scope == "harness";
  assert nixosAuthority.selectedUplink == "isp-primary";
  assert nixosAuthority.alternateUplinks == [ "overlay-secondary" ];
  assert nixosAuthority.root.zone == ".";
  assert nixosAuthority.delegation.zone == "dns-validation.test.";
  assert nixosAuthority.terminal.name == "answer.dns-validation.test.";
  assert nixosAuthority.trust.mode == "insecure-controlled-root";
  assert badScope.success == false;
  assert badSelection.success == false;
  true
' >/dev/null

echo "PASS FS-540 controlled iterative authority survives inventory to CPM"
