#!/usr/bin/env bash
# GAMP-ID: FS-275-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
archive_json="${tmp_dir}/flake-archive.json"
output_json="${tmp_dir}/cpm.json"
trap 'rm -rf "${tmp_dir}"' EXIT

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_path="$(jq -er '.inputs["network-labs"].path' "${archive_json}")"

nix run \
  --no-write-lock-file \
  --extra-experimental-features 'nix-command flakes' \
  "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/HAT/emulated-isp-residential-testnet/intent.nix" \
  "${labs_path}/HAT/emulated-isp-residential-testnet/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -e '
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

  def has_handoff:
    (.sourceScope | type == "object")
    and (.destinationScope | type == "object")
    and (.candidateEgress | type == "object")
    and (.policyPointTraversal | type == "object")
    and (.policyPointTraversal.nonBypass == true)
    and (.policyPointTraversal.sourceInterface == .fromInterface)
    and (.policyPointTraversal.destinationInterface == .toInterface)
    and (.sourceScope.runtimeInterface == .fromInterface)
    and (.destinationScope.runtimeInterface == .toInterface)
    and (.candidateEgress.runtimeInterface == .toInterface);

  def source_key:
    [ (.sourcePrefixes // [])[]? | { family: (.family // null), prefix: (.prefix // "") } ]
    | sort_by(.family // 0, .prefix);

  rules as $rules
  | interfaces as $interfaces
  | ($rules | map(select(.role == "policy"))) as $policyRules
  | ($rules | map(select((.relationId // "") | startswith("selector-handoff-")))) as $allSelectorHandoffs
  | ($allSelectorHandoffs | map(select(.role == "downstream-selector" or .role == "upstream-selector"))) as $selectorHandoffs
  | ($policyRules | map(select(.relationId == "allow-provider-handoff-a-to-isp-a" or .relationId == "allow-provider-handoff-b-to-isp-a"))) as $providerPolicy
  | ($policyRules | map(select(.relationId == "allow-iot-underlay-to-nebula-egress"))) as $nebulaPolicy
  | ($policyRules | map(select(.relationId == "allow-iot-underlay-to-wireguard-egress"))) as $wireguardPolicy
  | ($policyRules | map(select(.relationId == "allow-hat-site-dns-service-to-client-uplinks"))) as $dnsAllows
  | ($policyRules | map(select(.relationId == "deny-client-dns-to-uplinks"))) as $dnsDenies
  | {
      policyRuleCount: ($policyRules | length),
      allSelectorHandoffCount: ($allSelectorHandoffs | length),
      selectorHandoffCount: ($selectorHandoffs | length),
      providerSessionVirtualAdapters: ($interfaces | map(select(.adapterClass == "provider-session" and .virtualAdapter == true and .hostFacing == false)) | length),
      selectorFabricVirtualAdapters: ($interfaces | map(select(.adapterClass == "selector-fabric-link" and .virtualAdapter == true and .hostFacing == false)) | length),
      overlayVpnAdapters: ($interfaces | map(select(.sourceKind == "overlay" and .adapterClass == "vpn" and .virtualAdapter == true and .hostFacing == false)) | length),
      policyRulesMissingHandoff: ($policyRules | map(select(has_handoff | not)) | length),
      allSelectorHandoffsMissingHandoff: ($allSelectorHandoffs | map(select(has_handoff | not)) | length),
      selectorHandoffsMissingHandoff: ($selectorHandoffs | map(select(has_handoff | not)) | length),
      providerPolicy: $providerPolicy,
      nebulaPolicy: $nebulaPolicy,
      wireguardPolicy: $wireguardPolicy,
      dnsAllows: $dnsAllows,
      dnsDenies: $dnsDenies,
      ok:
        ($policyRules | length == 34)
        and ($allSelectorHandoffs | length == 236)
        and ($selectorHandoffs | length == 104)
        and (($interfaces | map(select(.adapterClass == "provider-session" and .virtualAdapter == true and .hostFacing == false)) | length) == 8)
        and (($interfaces | map(select(.adapterClass == "selector-fabric-link" and .virtualAdapter == true and .hostFacing == false)) | length) == 68)
        and (($interfaces | map(select(.sourceKind == "overlay" and .adapterClass == "vpn" and .virtualAdapter == true and .hostFacing == false)) | length) == 6)
        and all($policyRules[]; has_handoff)
        and all($allSelectorHandoffs[]; has_handoff)
        and all($selectorHandoffs[];
          has_handoff
          and .sourceScope.adapterClass == "selector-fabric-link"
          and .destinationScope.adapterClass == "selector-fabric-link"
          and .sourceScope.virtualAdapter == true
          and .destinationScope.virtualAdapter == true
        )
        and ($providerPolicy | length == 4)
        and all($providerPolicy[];
          has_handoff
          and (.sourceScope.lane.access | test("(nixos|clab)-provider-handoff-access-[ab]"))
          and .candidateEgress.uplink == "isp-a"
        )
        and ($nebulaPolicy | length == 2)
        and all($nebulaPolicy[];
          has_handoff
          and .candidateEgress.uplink == "nebula-egress"
          and .trafficType == "overlay-control"
        )
        and ($wireguardPolicy | length == 2)
        and all($wireguardPolicy[];
          has_handoff
          and .candidateEgress.uplink == "wireguard-egress"
          and .trafficType == "overlay-control"
        )
        and ($dnsAllows | length == 4)
        and ($dnsDenies | length == 4)
        and all($dnsAllows[];
          has_handoff
          and .action == "accept"
          and .trafficType == "dns"
          and (
            any((.sourcePrefixes // [])[]?; .family == 4 and .prefix == "10.20.20.1")
            or any((.sourcePrefixes // [])[]?; .family == 4 and .prefix == "10.50.20.1")
          )
          and (
            any((.sourcePrefixes // [])[]?; .family == 6 and .prefix == "fd42:dead:beef:20::1")
            or any((.sourcePrefixes // [])[]?; .family == 6 and .prefix == "fd42:dead:feed:20::1")
          )
        )
        and all($dnsDenies[];
          has_handoff
          and .action == "deny"
          and .trafficType == "dns"
          and ((.sourcePrefixes // []) == [])
        )
        and all($dnsAllows[];
          . as $allow
          | all($dnsDenies[];
            . as $deny
            | if
                $allow.fromInterface == $deny.fromInterface
                and $allow.toInterface == $deny.toInterface
                and $allow.trafficType == $deny.trafficType
                and (($allow.matches // []) == ($deny.matches // []))
              then
                ($allow | source_key) != ($deny | source_key)
              else
                true
              end
          )
        )
    }
  | select(.ok == true)
' "${output_json}" >/dev/null || {
  echo "FAIL fs275-virtual-adapter-transit-non-bypass: relation-bearing policy/selector handoff lacks explicit non-bypass scope/traversal fields or DNS identity collapsed" >&2
  jq '
    def rules:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | ($target.value.forwardingIntent.rules // [])[]?
        | . + { site: $site.key, target: $target.key, role: ($target.value.role // "") }
      ];
    rules as $rules
    | {
        policyRuleCount: ($rules | map(select(.role == "policy")) | length),
        policyRulesMissingHandoff: ($rules | map(select(.role == "policy" and ((has("sourceScope") and has("destinationScope") and has("candidateEgress") and has("policyPointTraversal")) | not))) | length),
        allSelectorHandoffCount: ($rules | map(select((.relationId // "") | startswith("selector-handoff-"))) | length),
        allSelectorHandoffsMissingHandoff: ($rules | map(select(((.relationId // "") | startswith("selector-handoff-")) and ((has("sourceScope") and has("destinationScope") and has("candidateEgress") and has("policyPointTraversal")) | not))) | length),
        selectorHandoffCount: ($rules | map(select(((.role == "downstream-selector") or (.role == "upstream-selector")) and ((.relationId // "") | startswith("selector-handoff-")))) | length),
        selectorHandoffsMissingHandoff: ($rules | map(select(((.role == "downstream-selector") or (.role == "upstream-selector")) and ((.relationId // "") | startswith("selector-handoff-")) and ((has("sourceScope") and has("destinationScope") and has("candidateEgress") and has("policyPointTraversal")) | not))) | length),
        providerPolicy: ($rules | map(select(.relationId == "allow-provider-handoff-a-to-isp-a" or .relationId == "allow-provider-handoff-b-to-isp-a"))),
        overlayPolicy: ($rules | map(select(.relationId == "allow-iot-underlay-to-nebula-egress" or .relationId == "allow-iot-underlay-to-wireguard-egress"))),
        dnsPolicy: ($rules | map(select(.relationId == "allow-hat-site-dns-service-to-client-uplinks" or .relationId == "deny-client-dns-to-uplinks")))
      }
  ' "${output_json}" >&2
  exit 1
}

echo "PASS fs275-virtual-adapter-transit-non-bypass"
