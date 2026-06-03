#!/usr/bin/env bash
# GAMP-ID: FS-170-HDS-010-SDS-010-SMS-010
# GAMP-ID: SMT-CPM-FORWARDING-INTENT-RULE-DEDUPLICATION-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"
duplicates_json="${tmp_dir}/duplicates.json"

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

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/ipv6-pd-downstream-delegation/intent.nix" \
  "${labs_path}/examples/ipv6-pd-downstream-delegation/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq '
  def rule_key($rule):
    [
      ($rule.action // ""),
      ($rule.fromInterface // ""),
      ($rule.toInterface // ""),
      (($rule.family // "") | tostring),
      ($rule.relationId // ""),
      ($rule.trafficType // ""),
      (($rule.applyTcpMssClamp // false) | tostring),
      (($rule.intent // {}) | tostring),
      (($rule.sourceFiles // []) | sort | tostring),
      (($rule.sourcePrefixes // []) | sort_by(.family // 0, .prefix // "") | tostring)
    ] | @json;

  [
    .control_plane_model.data
    | to_entries[] as $enterprise
    | $enterprise.value
    | to_entries[] as $site
    | ($site.value.runtimeTargets // {})
    | to_entries[] as $target
    | [($target.value.forwardingIntent.rules // [])[]] as $rules
    | ($rules | group_by(rule_key(.))[] | select(length > 1)) as $group
    | {
        enterprise: $enterprise.key,
        site: $site.key,
        target: $target.key,
        count: ($group | length),
        rule: $group[0]
      }
  ]
' "${output_json}" >"${duplicates_json}"

if [[ "$(jq 'length' "${duplicates_json}")" != "0" ]]; then
  echo "FAIL forwarding-intent-rule-deduplication: duplicate equivalent forwardingIntent.rules remain" >&2
  jq -S . "${duplicates_json}" >&2
  exit 1
fi

echo "PASS forwarding-intent-rule-deduplication"
