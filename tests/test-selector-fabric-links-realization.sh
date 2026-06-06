#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-SELECTOR-FABRIC-LINKS-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

archive_json="$(mktemp)"
trap 'rm -f "${archive_json}"' EXIT

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
    in
      if labs == null || !(labs ? path) then
        throw "selector-fabric-links-realization: missing archived network-labs input"
      else
        labs.path
  '
)"

INTENT_PATH="${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
INVENTORY_PATH="${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
REPO_ROOT="${repo_root}" \
NIX_SYSTEM="${system}" \
nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    lib = flake.inputs.nixpkgs.lib;
    builder = flake.lib.${builtins.getEnv "NIX_SYSTEM"}.compileAndBuild;
    input = import (builtins.getEnv "INTENT_PATH");
    baseInventory = import (builtins.getEnv "INVENTORY_PATH");
    nodes = baseInventory.realization.nodes;

    isSelector = target:
      let nodeName = target.logicalNode.name or "";
      in nodeName == "s-router-upstream-selector" || nodeName == "s-router-downstream-selector";

    linkPorts = ports:
      lib.filterAttrs
        (_: port: builtins.isString (port.link or null) && port.link != "")
        (if builtins.isAttrs ports then ports else { });

    selectorFabricLinks =
      lib.filterAttrs (_: value: value != { }) (
        lib.mapAttrs
          (_targetName: target:
            if isSelector target then
              lib.mapAttrs
                (_portName: port: {
                  kind = "selector-fabric-link";
                  link = port.link;
                  transport.hostFacing = false;
                })
                (linkPorts (target.ports or { }))
            else
              { })
          nodes
      );

    inventory =
      baseInventory
      // {
        realization =
          baseInventory.realization
          // {
            fabricLinks = selectorFabricLinks;
            nodes =
              lib.mapAttrs
                (_targetName: target: if isSelector target then target // { ports = { }; } else target)
                nodes;
          };
      };

    out = builder { inherit input inventory; };
    site = out.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets;
    selectorTargets = [
      site."esp0xdeadbeef-site-a-s-router-upstream-selector"
      site."esp0xdeadbeef-site-a-s-router-downstream-selector"
    ];
    selectorIfaces =
      builtins.concatLists (
        map (target: builtins.attrValues target.effectiveRuntimeRealization.interfaces) selectorTargets
      );
    selectorFabricOk =
      builtins.all
        (iface:
          (iface.sourceKind or null) == "p2p"
          && (iface.fabricLink.link or null) == (iface.backingRef.name or null)
          && (iface.fabricLink.transport.hostFacing or true) == false
          && !(iface ? adapterName)
          && !(iface ? attach))
        selectorIfaces;

    accessTargetName = "esp0xdeadbeef-site-a-s-router-access-client";
    accessTarget = nodes.${accessTargetName};
    accessLinkPortNames = builtins.attrNames (linkPorts accessTarget.ports);
    missingAccessInventory =
      baseInventory
      // {
        realization =
          baseInventory.realization
          // {
            nodes =
              nodes
              // {
                ${accessTargetName} =
                  accessTarget
                  // {
                    ports = builtins.removeAttrs accessTarget.ports [ (builtins.head accessLinkPortNames) ];
                  };
              };
          };
      };
    missingAccessResult =
      builtins.tryEval (builtins.deepSeq (builder { input = input; inventory = missingAccessInventory; }) true);
  in
    selectorFabricOk
    && builtins.length selectorIfaces == 29
    && builtins.length (builtins.attrNames selectorFabricLinks) == 2
    && !missingAccessResult.success
' | grep -qx true

echo "PASS selector-fabric-links-realization"
