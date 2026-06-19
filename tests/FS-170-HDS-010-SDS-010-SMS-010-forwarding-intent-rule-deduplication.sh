#!/usr/bin/env bash
# GAMP-ID: FS-170-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-170-HDS-010-SDS-010-SMS-030
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
equivalence_json="${tmp_dir}/equivalence.json"

REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    precedence = import (repoRoot + "/src/cpm/firewall-intent/precedence.nix") { };
    baseRule = {
      action = "accept";
      relationId = "allow-client-dns";
      priority = 30;
      trafficType = "dns";
      matches = [
        { proto = "udp"; dstPort = 53; }
        { proto = "tcp"; dstPort = 53; }
      ];
      fromInterface = "tenant0";
      toInterface = "policy0";
      family = 4;
      sourcePrefixes = [
        {
          family = 4;
          prefix = "10.20.0.0/24";
          origin = { diagnostic = "first"; };
        }
      ];
      applyTcpMssClamp = false;
      intent = { kind = "modeled-policy"; };
      from = { tag = "client"; diagnostic = "first"; };
      to = { tag = "resolver"; diagnostic = "first"; };
      comment = "metadata-first";
    };
    metadataVariant =
      baseRule
      // {
        sourcePrefixes = [
          {
            family = 4;
            prefix = "10.20.0.0/24";
            origin = { diagnostic = "second"; };
          }
        ];
        from = { tag = "client"; diagnostic = "second"; };
        to = { tag = "resolver"; diagnostic = "second"; };
        comment = "metadata-second";
      };
    distinctPriority = baseRule // { priority = 31; comment = "distinct-priority"; };
    distinctMatch = baseRule // {
      matches = [ { proto = "udp"; dstPort = 53; } ];
      comment = "distinct-match";
    };
    distinctSource = baseRule // {
      sourcePrefixes = [ { family = 4; prefix = "10.21.0.0/24"; } ];
      comment = "distinct-source";
    };
    entry = builtins.head (precedence.sortEntries [
      {
        name = "policy-target";
        value = {
          mode = "explicit-policy-forwarding";
          rules = [
            baseRule
            metadataVariant
            distinctPriority
            distinctMatch
            distinctSource
          ];
        };
      }
    ]);
    comments = map (rule: rule.comment or "") entry.value.rules;
    metadataRepresentatives =
      builtins.filter
        (comment: comment == "metadata-first" || comment == "metadata-second")
        comments;
  in
  {
    count = builtins.length entry.value.rules;
    metadataRepresentativeCount = builtins.length metadataRepresentatives;
    keptDistinctPriority = builtins.elem "distinct-priority" comments;
    keptDistinctMatch = builtins.elem "distinct-match" comments;
    keptDistinctSource = builtins.elem "distinct-source" comments;
  }
' >"${equivalence_json}"

if ! jq -e '
  .count == 4
  and .metadataRepresentativeCount == 1
  and .keptDistinctPriority == true
  and .keptDistinctMatch == true
  and .keptDistinctSource == true
' "${equivalence_json}" >/dev/null; then
  echo "FAIL forwarding-intent-rule-deduplication: policy equivalence key collapsed or preserved the wrong records" >&2
  jq -S . "${equivalence_json}" >&2
  exit 1
fi

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
  "${labs_path}/examples/single-wan/intent.nix" \
  "${labs_path}/examples/single-wan/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq '
  def rule_key($rule):
    [
      ($rule.action // ""),
      ($rule.fromInterface // ""),
      ($rule.toInterface // ""),
      (($rule.family // "") | tostring),
      ($rule.relationId // ""),
      (($rule.priority // null) | tostring),
      ($rule.trafficType // ""),
      (($rule.matches // []) | sort_by(tostring) | tostring),
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
