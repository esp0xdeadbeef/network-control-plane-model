#!/usr/bin/env bash
# GAMP-ID: FS-275-HDS-010-SDS-010-SMS-010
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

validate_transit_non_bypass() {
  local input="$1"
  local inventory_label="$2"
  local mode="${3:-verbose}"
  local summary="${tmp_dir}/$(basename "${input}").${inventory_label}.summary.json"

  jq --arg inventory "${inventory_label}" '
    def non_empty_string($v):
      ($v | type) == "string" and $v != "";

    def rules:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | ($target.value.forwardingIntent.rules // [])[]?
        | . + {
            site: $site.key,
            target: $target.key,
            role: ($target.value.role // "")
          }
      ];

    def interfaces:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | (($target.value.effectiveRuntimeRealization.interfaces // {}) | to_entries[]?)
        | .value + {
            site: $site.key,
            target: $target.key,
            logicalInterface: .key,
            role: ($target.value.role // "")
          }
      ];

    def scope_common($scope):
      ($scope | type) == "object"
      and non_empty_string($scope.runtimeInterface // "")
      and (($scope.backingRef // null) | type) == "object"
      and non_empty_string($scope.backingRef.name // "")
      and ($scope | has("hostFacing"))
      and (($scope.hostFacing | type) == "boolean")
      and ($scope | has("virtualAdapter"))
      and (($scope.virtualAdapter | type) == "boolean");

    def virtual_transit_scope($scope):
      if $scope.virtualAdapter == true then
        $scope.hostFacing == false
        and non_empty_string($scope.adapterClass // "")
        and (($scope.sourceKind // "") != "host-local")
        and (($scope.relationPurpose // "") != "host-local")
        and (
          $scope.adapterClass == "selector-fabric-link"
          or $scope.adapterClass == "provider-session"
          or ($scope.adapterClass == "vpn" and ($scope.sourceKind // "") == "overlay")
        )
      else
        true
      end;

    def handoff_scopes_ok($rule):
      all([$rule.sourceScope, $rule.destinationScope, $rule.candidateEgress][];
        scope_common(.) and virtual_transit_scope(.)
      );

    def has_handoff($rule):
      non_empty_string($rule.relationId // "")
      and non_empty_string($rule.action // "")
      and non_empty_string($rule.trafficType // "")
      and non_empty_string($rule.direction // "")
      and non_empty_string($rule.fromInterface // "")
      and non_empty_string($rule.toInterface // "")
      and handoff_scopes_ok($rule)
      and (($rule.policyPointTraversal // null) | type) == "object"
      and ($rule.policyPointTraversal | has("nonBypass"))
      and $rule.policyPointTraversal.nonBypass == true
      and $rule.policyPointTraversal.relationId == $rule.relationId
      and $rule.policyPointTraversal.action == $rule.action
      and $rule.policyPointTraversal.sourceInterface == $rule.fromInterface
      and $rule.policyPointTraversal.destinationInterface == $rule.toInterface
      and $rule.sourceScope.runtimeInterface == $rule.fromInterface
      and $rule.destinationScope.runtimeInterface == $rule.toInterface
      and $rule.candidateEgress.runtimeInterface == $rule.toInterface;

    def source_key:
      [ (.sourcePrefixes // [])[]? | { family: (.family // null), prefix: (.prefix // "") } ]
      | sort_by(.family // 0, .prefix);

    rules as $rules
    | interfaces as $interfaces
    | ($rules | map(select(.role == "policy"))) as $policyRules
    | ($rules | map(select((.relationId // "") | startswith("selector-handoff-")))) as $allSelectorHandoffs
    | ($allSelectorHandoffs | map(select(.role == "downstream-selector" or .role == "upstream-selector"))) as $selectorHandoffs
    | ($policyRules + $allSelectorHandoffs) as $relationRules
    | ($policyRules | map(select(.relationId == "allow-provider-handoff-a-to-isp-a" or .relationId == "allow-provider-handoff-b-to-isp-a"))) as $providerPolicy
    | ($policyRules | map(select(.relationId == "allow-iot-underlay-to-nebula-egress"))) as $nebulaPolicy
    | ($policyRules | map(select(.relationId == "allow-iot-underlay-to-wireguard-egress"))) as $wireguardPolicy
    | ($policyRules | map(select(.relationId == "allow-hat-site-dns-service-to-client-uplinks"))) as $dnsAllows
    | ($policyRules | map(select(.relationId == "deny-client-dns-to-uplinks"))) as $dnsDenies
    | ($providerPolicy | map(select(has_handoff(.) | not))) as $badProviderPolicy
    | ($nebulaPolicy | map(select(has_handoff(.) | not))) as $badNebulaPolicy
    | ($wireguardPolicy | map(select(has_handoff(.) | not))) as $badWireguardPolicy
    | ($dnsAllows | map(select((has_handoff(.) and .action == "accept" and .trafficType == "dns" and ((.sourcePrefixes // []) | length > 0)) | not))) as $badDnsAllows
    | ($dnsDenies | map(select((has_handoff(.) and .action == "deny" and .trafficType == "dns" and ((.sourcePrefixes // []) == [])) | not))) as $badDnsDenies
    | ([
        $dnsAllows[] as $allow
        | $dnsDenies[] as $deny
        | select(
            $allow.fromInterface == $deny.fromInterface
            and $allow.toInterface == $deny.toInterface
            and $allow.trafficType == $deny.trafficType
            and (($allow.matches // []) == ($deny.matches // []))
            and (($allow | source_key) == ($deny | source_key))
          )
      ]) as $dnsCollapsed
    | {
        trace: "FS-275-HDS-010-SDS-010-SMS-010",
        inventory: $inventory,
        policyRuleCount: ($policyRules | length),
        allSelectorHandoffCount: ($allSelectorHandoffs | length),
        selectorHandoffCount: ($selectorHandoffs | length),
        providerSessionVirtualAdapters: ($interfaces | map(select(.adapterClass == "provider-session" and .virtualAdapter == true and .hostFacing == false)) | length),
        selectorFabricVirtualAdapters: ($interfaces | map(select(.adapterClass == "selector-fabric-link" and .virtualAdapter == true and .hostFacing == false)) | length),
        overlayVpnAdapters: ($interfaces | map(select(.sourceKind == "overlay" and .adapterClass == "vpn" and .virtualAdapter == true and .hostFacing == false)) | length),
        virtualTransitSurfaceCount: ($interfaces | map(select(.virtualAdapter == true and .hostFacing == false and (.adapterClass == "selector-fabric-link" or .adapterClass == "provider-session" or (.sourceKind == "overlay" and .adapterClass == "vpn")))) | length),
        relationRulesMissingHandoff: ($relationRules | map(select(has_handoff(.) | not)) | length),
        invalidRelationSample: ($relationRules | map(select(has_handoff(.) | not))[:3] | map({target, role, relationId, sourceScope, destinationScope, candidateEgress, policyPointTraversal})),
        providerPolicyCount: ($providerPolicy | length),
        badProviderPolicyCount: ($badProviderPolicy | length),
        nebulaPolicyCount: ($nebulaPolicy | length),
        badNebulaPolicyCount: ($badNebulaPolicy | length),
        wireguardPolicyCount: ($wireguardPolicy | length),
        badWireguardPolicyCount: ($badWireguardPolicy | length),
        dnsAllowCount: ($dnsAllows | length),
        badDnsAllowCount: ($badDnsAllows | length),
        dnsDenyCount: ($dnsDenies | length),
        badDnsDenyCount: ($badDnsDenies | length),
        dnsCollapsedCount: ($dnsCollapsed | length),
        ok:
          ($policyRules | length > 0)
          and ($allSelectorHandoffs | length > 0)
          and ($selectorHandoffs | length > 0)
          and (($interfaces | map(select(.adapterClass == "selector-fabric-link" and .virtualAdapter == true and .hostFacing == false)) | length) > 0)
          and (($interfaces | map(select(.sourceKind == "overlay" and .adapterClass == "vpn" and .virtualAdapter == true and .hostFacing == false)) | length) > 0)
          and (($interfaces | map(select(.virtualAdapter == true and .hostFacing == false and (.adapterClass == "selector-fabric-link" or .adapterClass == "provider-session" or (.sourceKind == "overlay" and .adapterClass == "vpn")))) | length) > 0)
          and all($relationRules[]; has_handoff(.))
          and all($selectorHandoffs[]; has_handoff(.))
          and ($providerPolicy | length > 0)
          and all($providerPolicy[]; has_handoff(.))
          and ($nebulaPolicy | length > 0)
          and all($nebulaPolicy[]; has_handoff(.))
          and ($wireguardPolicy | length > 0)
          and all($wireguardPolicy[]; has_handoff(.))
          and ($dnsAllows | length > 0)
          and ($dnsDenies | length > 0)
          and all($dnsAllows[];
            has_handoff(.)
            and .action == "accept"
            and .trafficType == "dns"
            and ((.sourcePrefixes // []) | length > 0)
          )
          and all($dnsDenies[];
            has_handoff(.)
            and .action == "deny"
            and .trafficType == "dns"
            and ((.sourcePrefixes // []) == [])
          )
          and (($dnsCollapsed | length) == 0)
      }
  ' "${input}" > "${summary}"

  if jq -e '.ok == true' "${summary}" >/dev/null; then
    return 0
  fi

  if [[ "${mode}" != "quiet" ]]; then
    echo "FAIL FS-275-HDS-010-SDS-010-SMS-010 ${inventory_label}: virtual adapter transit relation preservation contract was not met" >&2
    jq . "${summary}" >&2
  fi
  return 1
}

mutate_transit_contract() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def relation_rule:
      (.role == "policy")
      or ((.relationId // "") | startswith("selector-handoff-"));

    def has_virtual_scope:
      ((.sourceScope.virtualAdapter? // false) == true)
      or ((.destinationScope.virtualAdapter? // false) == true)
      or ((.candidateEgress.virtualAdapter? // false) == true);

    if $mutation == "lost-transit-relation" then
      (.. | objects | select(relation_rule and has_virtual_scope)) |= del(.policyPointTraversal)
    elif $mutation == "false-transit-claim" then
      (.. | objects | select(relation_rule and has_virtual_scope) | .sourceScope) |= (
        .adapterClass = "host-local-virtual"
        | .sourceKind = "host-local"
        | .relationPurpose = "host-local"
        | .virtualAdapter = true
        | .hostFacing = false
      )
    else
      .
    end
  ' "${input}" > "${output}"
}

assert_rejects() {
  local input="$1"
  local inventory="$2"
  local label="$3"

  if validate_transit_non_bypass "${input}" "${inventory}-${label}" quiet; then
    echo "FAIL FS-275-HDS-010-SDS-010-SMS-010 ${inventory} ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-275-HDS-010-SDS-010-SMS-010 ${inventory} ${label}: seeded violation rejected"
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

for case in "nixos:${nixos_output}" "clab:${clab_output}"; do
  inventory="${case%%:*}"
  output="${case#*:}"

  validate_transit_non_bypass "${output}" "${inventory}"

  lost_relation="${tmp_dir}/${inventory}.lost-transit-relation.json"
  false_claim="${tmp_dir}/${inventory}.false-transit-claim.json"

  mutate_transit_contract "${output}" "${lost_relation}" "lost-transit-relation"
  mutate_transit_contract "${output}" "${false_claim}" "false-transit-claim"

  assert_rejects "${lost_relation}" "${inventory}" "lost-transit-relation"
  assert_rejects "${false_claim}" "${inventory}" "false-transit-claim"

  validate_transit_non_bypass "${output}" "${inventory}"
done

echo "PASS fs275-virtual-adapter-transit-non-bypass"
