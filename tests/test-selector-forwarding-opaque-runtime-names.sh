#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

archive_json="$(mktemp)"
output_json="$(mktemp)"
trap 'rm -f "${archive_json}" "${output_json}"' EXIT

nix_args=()
if [[ -n "${NETWORK_FORWARDING_MODEL_OVERRIDE:-}" ]]; then
  nix_args+=(--override-input network-forwarding-model "${NETWORK_FORWARDING_MODEL_OVERRIDE}")
fi

nix flake archive "${nix_args[@]}" --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
    in
      if labs == null || !(labs ? path) then
        throw "selector-forwarding-opaque-runtime-names: missing archived network-labs input"
      else
        labs.path
  '
)"

INTENT_PATH="${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
INVENTORY_PATH="${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
REPO_ROOT="${repo_root}" \
NIX_SYSTEM="${system}" \
nix eval --impure "${nix_args[@]}" --json --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    lib = flake.inputs.nixpkgs.lib;
    builder = flake.lib.${builtins.getEnv "NIX_SYSTEM"}.compileAndBuild;
    input = import (builtins.getEnv "INTENT_PATH");
    baseInventory = import (builtins.getEnv "INVENTORY_PATH");

    renamePorts = _targetName: target:
      target
      // {
        ports =
          builtins.listToAttrs (
            builtins.genList
              (idx:
                let
                  portName = builtins.elemAt (lib.attrNames target.ports) idx;
                  port = target.ports.${portName};
                in
                {
                  name = portName;
                  value =
                    port
                    // {
                      interface = (port.interface or { }) // { name = "if${toString idx}"; };
                    };
                })
              (builtins.length (lib.attrNames target.ports))
          );
      };

    inventory =
      baseInventory
      // {
        realization =
          baseInventory.realization
          // {
            nodes = lib.mapAttrs renamePorts baseInventory.realization.nodes;
          };
      };

    out = builder { inherit input inventory; };

    target = out.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets."esp0xdeadbeef-site-a-s-router-upstream-selector";
    interfaces = target.effectiveRuntimeRealization.interfaces;
    rules = target.forwardingIntent.rules or [ ];

    attrsOrEmpty = value: if builtins.isAttrs value then value else { };
    laneFor = iface: attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);
    uplinksFor = iface: (attrsOrEmpty (iface.backingRef or null)).uplinks or [ ];

    coreInterfaces =
      builtins.filter
        (iface: (iface.sourceKind or null) == "p2p" && (uplinksFor iface) != [ ])
        (builtins.attrValues interfaces);

    policyInterfaces =
      builtins.filter
        (iface:
          let lane = laneFor iface;
          in (iface.sourceKind or null) == "p2p" && (lane.access or null) != null && (lane.uplink or null) != null)
        (builtins.attrValues interfaces);

    ruleExists = from: to:
      builtins.any
        (rule: (rule.fromInterface or null) == from && (rule.toInterface or null) == to)
        rules;

    matchingCoreForPolicy = policyIface:
      let
        policyLane = laneFor policyIface;
        matching = builtins.filter (coreIface: builtins.elem policyLane.uplink (uplinksFor coreIface)) coreInterfaces;
      in
      if matching == [ ] then null else builtins.head matching;

    policyPairOk = policyIface:
      let coreIface = matchingCoreForPolicy policyIface;
      in
      coreIface != null
      && ruleExists policyIface.runtimeIfName coreIface.runtimeIfName
      && ruleExists coreIface.runtimeIfName policyIface.runtimeIfName;

    ok = policyInterfaces != [ ] && builtins.all policyPairOk policyInterfaces;
  in
    if ok then
      true
    else
      throw "selector-forwarding-opaque-runtime-names failed: upstream-selector forwarding rules must pair policy-side access/uplink lanes to core-side uplink lanes after runtime interface names are made opaque. Fix CPM to consume backingRef.lane/backingRef.uplinks, not runtimeIfName/sourceInterfaceName fragments."
' >"${output_json}"

echo "PASS selector-forwarding-opaque-runtime-names"
