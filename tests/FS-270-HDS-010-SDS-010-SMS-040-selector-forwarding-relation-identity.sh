#!/usr/bin/env bash
# GAMP-ID: FS-270-HDS-010-SDS-010-SMS-040
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"
nixos_output="${tmp_dir}/nixos-cpm.json"
clab_output="${tmp_dir}/clab-cpm.json"

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

validate_selector_rules() {
  local input="$1"

  jq -e '
    def selector_rule:
      ((.relationCardinality.unit // "") == "selector-forwarding-rule")
      or ((.relationId // "") | startswith("selector-handoff-"));

    def non_empty_string($v):
      ($v | type) == "string" and $v != "";

    def metadata_scope($scope):
      ($scope | type) == "object"
      and non_empty_string($scope.runtimeInterface // "")
      and (($scope.lane // null) | type) == "object"
      and (($scope.backingRef // null) | type) == "object"
      and non_empty_string($scope.backingRef.name // "")
      and ($scope | has("hostFacing"))
      and ($scope.hostFacing | type) == "boolean";

    def valid_cardinality($rule):
      (($rule.relationCardinality // null) | type) == "object"
      and $rule.relationCardinality.unit == "selector-forwarding-rule"
      and non_empty_string($rule.relationCardinality.decomposition // "")
      and ($rule.relationCardinality | has("decomposed"))
      and ($rule.relationCardinality.decomposed | type) == "boolean";

    [
      .control_plane_model.data
      | to_entries[] as $enterprise
      | $enterprise.value
      | to_entries[] as $site
      | $site.value.runtimeTargets
      | to_entries[] as $target
      | ($target.value.forwardingIntent.rules // [])[]
      | select(selector_rule)
      | . + {
          enterprise: $enterprise.key,
          site: $site.key,
          target: $target.key
        }
    ] as $rules
    | [
        $rules[]
        | select(
            ((.action // "") as $a | ($a != "accept" and $a != "deny"))
            or (non_empty_string(.relationId // "") | not)
            or ((.comment // null) != (.relationId // null))
            or (non_empty_string(.trafficType // "") | not)
            or (non_empty_string(.direction // "") | not)
            or (non_empty_string(.fromInterface // "") | not)
            or (non_empty_string(.toInterface // "") | not)
            or (metadata_scope(.sourceScope // null) | not)
            or (metadata_scope(.destinationScope // null) | not)
            or (metadata_scope(.candidateEgress // null) | not)
            or (((.policyPointTraversal // null) | type) != "object")
            or ((.policyPointTraversal.nonBypass // null) != true)
            or (non_empty_string(.policyPointTraversal.relationId // "") | not)
            or (valid_cardinality(.) | not)
          )
      ] as $invalid
    | {
        trace: "FS-270-HDS-010-SDS-010-SMS-040",
        selectorRuleCount: ($rules | length),
        invalidCount: ($invalid | length),
        invalidSample: ($invalid[:3] | map({target, relationId, comment, sourceScope, destinationScope, candidateEgress, relationCardinality}))
      }
    | select(.selectorRuleCount > 0 and .invalidCount == 0)
  ' "${input}" >/dev/null
}

mutate_selector_rules() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def is_selector:
      ((.relationCardinality.unit // "") == "selector-forwarding-rule")
      or ((.relationId // "") | startswith("selector-handoff-"));

    if $mutation == "missing-relation" then
      (.. | objects | select(is_selector)) |= del(.relationId)
    elif $mutation == "missing-source-scope" then
      (.. | objects | select(is_selector)) |= del(.sourceScope)
    elif $mutation == "bad-cardinality" then
      (.. | objects | select(is_selector)) |= (.relationCardinality.unit = "broad-unlabeled-rule")
    elif $mutation == "missing-candidate-egress" then
      (.. | objects | select(is_selector)) |= del(.candidateEgress.backingRef.name)
    else
      .
    end
  ' "${input}" > "${output}"
}

assert_rejects() {
  local input="$1"
  local label="$2"

  if validate_selector_rules "${input}"; then
    echo "FAIL FS-270-HDS-010-SDS-010-SMS-040 ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-270-HDS-010-SDS-010-SMS-040 ${label}: seeded violation rejected"
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

validate_selector_rules "${nixos_output}"
validate_selector_rules "${clab_output}"

for output in "${nixos_output}" "${clab_output}"; do
  missing_relation="${tmp_dir}/$(basename "${output}").missing-relation.json"
  missing_source="${tmp_dir}/$(basename "${output}").missing-source-scope.json"
  bad_cardinality="${tmp_dir}/$(basename "${output}").bad-cardinality.json"
  missing_egress="${tmp_dir}/$(basename "${output}").missing-candidate-egress.json"

  mutate_selector_rules "${output}" "${missing_relation}" "missing-relation"
  mutate_selector_rules "${output}" "${missing_source}" "missing-source-scope"
  mutate_selector_rules "${output}" "${bad_cardinality}" "bad-cardinality"
  mutate_selector_rules "${output}" "${missing_egress}" "missing-candidate-egress"

  assert_rejects "${missing_relation}" "missing-relation"
  assert_rejects "${missing_source}" "missing-source-scope"
  assert_rejects "${bad_cardinality}" "bad-cardinality"
  assert_rejects "${missing_egress}" "missing-candidate-egress"

  validate_selector_rules "${output}"
done

echo "PASS selector-forwarding-relation-identity"
