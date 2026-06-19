#!/usr/bin/env bash
# GAMP-ID: FS-170-HDS-010-SDS-010-SMS-020
# GAMP-ID: SMT-CPM-MODELED-DENY-RESOLVED-RECORD-001
# GAMP-SCOPE: software-module-test
# Focused construction test: SMS-020 SN1 — resolved deny produces explicit deny record.
#
# SMS-020 SN1: "Inject a modeled deny relation with fully resolved source and
# destination surfaces, then verify the construction test confirms an explicit
# deny record is emitted with relation ID, priority, traffic type, and endpoint
# metadata intact — rather than the deny being silently omitted after endpoint
# resolution."
#
# Uses the single-wan example (still present in network-labs) via
# compileAndBuildFromPaths. A deny relation is overlaid inline by writing a
# temp Nix file that imports and overlays the base intent.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
modified_intent="${tmp_dir}/intent-modified.nix"

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then throw "tests: missing archived network-labs input path" else labsPath
  '
)"

# Write a Nix file that imports the single-wan intent and overlays a deny relation
cat >"${modified_intent}" <<NIXEOF
let
  base = import (builtins.getEnv "LABS_PATH" + "/examples/single-wan/intent.nix");
  site = base.esp0xdeadbeef."site-a";
  contract = site.communicationContract;
  denyRelation = {
    action = "deny";
    from = {
      kind = "tenant-set";
      members = [ "admin" ];
    };
    id = "deny-admin-to-wan";
    priority = 90;
    to = {
      kind = "external";
      name = "wan";
    };
    trafficType = "any";
  };
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      communicationContract = contract // {
        relations = contract.relations ++ [ denyRelation ];
        allowedRelations = contract.allowedRelations or [] ++ [ denyRelation ];
      };
    };
  };
}
NIXEOF

# Build CPM and verify the deny rule
export LABS_PATH="${labs_path}"
export REPO_ROOT="${repo_root}"
export MODIFIED_INTENT="${modified_intent}"

nix eval --impure --expr '
  let
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    labsPath = builtins.getEnv "LABS_PATH";

    built = flake.lib.${system}.compileAndBuildFromPaths {
      inputPath = builtins.getEnv "MODIFIED_INTENT";
      inventoryPath = labsPath + "/examples/single-wan/inventory-nixos.nix";
    };

    siteData = built.control_plane_model.data.esp0xdeadbeef."site-a";
    rules = siteData.runtimeTargets."esp0xdeadbeef-site-a-s-router-policy".forwardingIntent.rules or [];

    denyRules = builtins.filter
      (rule: (rule.relationId or null) == "deny-admin-to-wan")
      rules;

    denyRule = if denyRules != [] then builtins.head denyRules else null;

    checks = {
      denyRuleCount = builtins.length denyRules > 0;
      actionIsDeny = (denyRule.action or null) == "deny";
      relationIdMatch = (denyRule.relationId or null) == "deny-admin-to-wan";
      priorityMatch = (denyRule.priority or null) == 90;
      trafficTypeMatch = (denyRule.trafficType or null) == "any";
      fromKindMatch = (denyRule.from.kind or null) == "tenant-set";
      fromMembersContainAdmin = builtins.elem "admin" (denyRule.from.members or []);
      toKindMatch = (denyRule.to.kind or null) == "external";
      toNameMatch = (denyRule.to.name or null) == "wan";
      hasFromInterface = builtins.isString (denyRule.fromInterface or "") && (denyRule.fromInterface or "") != "";
      hasToInterface = builtins.isString (denyRule.toInterface or "") && (denyRule.toInterface or "") != "";
    };

    allPass = builtins.all (value: value == true) (builtins.attrValues checks);
  in
    if allPass then
      true
    else
      throw ("FS-170-HDS-010-SDS-010-SMS-020 resolved-deny-explicit-record checks failed: " + builtins.toJSON checks)
' >/dev/null

echo "PASS FS-170-HDS-010-SDS-010-SMS-020-resolved-deny-explicit-record"
