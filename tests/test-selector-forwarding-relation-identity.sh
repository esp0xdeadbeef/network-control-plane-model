#!/usr/bin/env bash
# GAMP-ID: FS-270-HDS-010-SDS-010-SMS-040
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-040
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
        throw "selector-forwarding-relation-identity: missing archived network-labs input"
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
    inventory = import (builtins.getEnv "INVENTORY_PATH");
    out = builder { inherit input inventory; };
    targets = out.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets;

    runtimeTargets = [
      targets."esp0xdeadbeef-site-a-s-router-downstream-selector"
      targets."esp0xdeadbeef-site-a-s-router-upstream-selector"
      targets."esp0xdeadbeef-site-a-s-router-policy"
    ];

    runtimeRules =
      builtins.concatLists (
        map (target: target.forwardingIntent.rules or [ ]) runtimeTargets
      );

    nonEmpty = value: builtins.isString value && value != "";
    attrs = value: builtins.isAttrs value;
    list = value: builtins.isList value;

    validSelectorScope = scope:
      attrs scope
      && nonEmpty (scope.runtimeInterface or "")
      && nonEmpty (scope.relationPurpose or "")
      && attrs (scope.lane or null)
      && attrs (scope.backingRef or null)
      && (scope.hostFacing or true) == false;

    selectorScopedRule = rule:
      builtins.match "selector-handoff-.*" (rule.relationId or "") != null
      || (rule.relationId or null) == "runtime-origin-egress"
      || (rule.relationId or null) == "runtime-routed-prefix-public-egress";

    validCardinality = rule:
      attrs (rule.relationCardinality or null)
      && builtins.elem (rule.relationCardinality.unit or null) [
        "selector-forwarding-rule"
        "policy-router-forwarding-rule"
      ]
      && nonEmpty (rule.relationCardinality.decomposition or "")
      && builtins.isBool (rule.relationCardinality.decomposed or null);

    validRule = rule:
      attrs rule
      && builtins.elem (rule.action or null) [ "accept" "deny" ]
      && nonEmpty (rule.relationId or "")
      && (rule.comment or null) == rule.relationId
      && nonEmpty (rule.trafficType or "")
      && nonEmpty (rule.direction or "")
      && nonEmpty (rule.fromInterface or "")
      && nonEmpty (rule.toInterface or "")
      && attrs (rule.from or null)
      && attrs (rule.to or null)
      && (
        !(selectorScopedRule rule)
        || (validSelectorScope (rule.from or null) && validSelectorScope (rule.to or null))
      )
      && validCardinality rule
      && (!(rule ? sourcePrefixes) || list rule.sourcePrefixes);

    invalidRules = builtins.filter (rule: !(validRule rule)) runtimeRules;
  in
    runtimeRules != [ ]
    && invalidRules == [ ]
' | grep -qx true

echo "PASS selector-forwarding-relation-identity"
