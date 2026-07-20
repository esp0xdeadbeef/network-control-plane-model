#!/usr/bin/env bash
# GAMP-ID: FS-305-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
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

validate_hygiene_boundary() {
  local input="$1"
  local inventory_label="$2"
  local mode="${3:-verbose}"
  local summary="${tmp_dir}/$(basename "${input}").${inventory_label}.summary.json"

  jq --arg inventory "${inventory_label}" '
    def targets:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | $target.value + { target: $target.key, site: $site.key }
      ];

    def interfaces:
      [
        targets[] as $target
        | (($target.effectiveRuntimeRealization.interfaces // {}) | to_entries[]?)
        | .value + {
            target: $target.target,
            site: $target.site,
            logicalInterface: .key,
            role: ($target.role // "")
          }
      ];

    def rules:
      [
        targets[] as $target
        | ($target.forwardingIntent.rules // [])[]?
        | . + {
            target: $target.target,
            site: $target.site,
            role: ($target.role // "")
          }
      ];

    def has_hygiene_fields:
      has("boundaryIdentity")
      or has("sourceScopeAuthority")
      or has("hygieneDecision")
      or has("spoofing")
      or has("hygieneBoundary");

    def has_boundary:
      (.boundaryIdentity.kind == "virtual-adapter-hygiene-boundary")
      and ((.boundaryIdentity.adapterClass // "") == (.adapterClass // ""))
      and (.sourceScopeAuthority.authority == "control-plane-model")
      and (.sourceScopeAuthority.failClosedWhenAbsent == true)
      and (.sourceScopeAuthority.mode == "structured-source-scope")
      and (.hygieneDecision.enforcement == "fail-closed")
      and (.hygieneDecision.interfaceTupleOnlyAuthority == false)
      and (.hygieneDecision.unscopedSourceAccepted == false)
      and (.spoofing.rejection == "fail-closed")
      and (.spoofing.interfaceTupleOnlyBypass == false)
      and (.spoofing.spoofedSourceAccepted == false)
      and (.hygieneBoundary.provenance.route.gate == "route-intent-and-policy-only-classification")
      and (.hygieneBoundary.provenance.firewall.gate == "relation-handoff")
      and (.hygieneBoundary.provenance.nat.gate == "route-safety")
      and (.hygieneBoundary.provenance.providerEgress.gate == "provider-egress-source");

    def scope_boundary_ok:
      if (.virtualAdapter // false) == true then
        has_boundary
      else
        has_hygiene_fields | not
      end;

    def source_key:
      [ (.sourcePrefixes // [])[]? | { family: (.family // null), prefix: (.prefix // "") } ]
      | sort_by(.family // 0, .prefix);

    interfaces as $ifaces
    | rules as $rules
    | ($ifaces | map(select(.virtualAdapter == true))) as $virtual
    | ($virtual | map(select(.adapterClass == "provider-session"))) as $provider
    | ($virtual | map(select(.adapterClass == "selector-fabric-link"))) as $selector
    | ($virtual | map(select(.sourceKind == "overlay" and .adapterClass == "vpn"))) as $overlayVpn
    | ($ifaces | map(select(.sourceKind == "p2p" and .hostFacing == true))) as $hostP2p
    | ($ifaces | map(select(.sourceKind == "tenant" and .hostFacing == true))) as $hostTenant
    | ($rules | map(select((.relationId // "") | startswith("selector-handoff-")))) as $selectorRules
    | ($rules | map(select(.relationId == "allow-provider-handoff-a-to-isp-a" or .relationId == "allow-provider-handoff-b-to-isp-a"))) as $providerRules
    | ($rules | map(select(.relationId == "allow-iot-underlay-to-nebula-egress" or .relationId == "allow-iot-underlay-to-wireguard-egress"))) as $overlayRules
    | ($rules | map(select(.relationId == "allow-hat-site-dns-service-to-client-uplinks"))) as $dnsAllows
    | ($rules | map(select(.relationId == "deny-client-dns-to-uplinks"))) as $dnsDenies
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
        trace: "FS-305-HDS-010-SDS-010-SMS-010",
        inventory: $inventory,
        virtualCount: ($virtual | length),
        providerSessionCount: ($provider | length),
        selectorFabricLinkCount: ($selector | length),
        overlayVpnCount: ($overlayVpn | length),
        virtualMissingBoundary: ($virtual | map(select(has_boundary | not)) | length),
        virtualHostFacingPromoted: ($virtual | map(select(.hostFacing != false)) | length),
        hostP2pPromoted: ($hostP2p | map(select(has_hygiene_fields)) | length),
        hostTenantPromoted: ($hostTenant | map(select(has_hygiene_fields)) | length),
        selectorRuleCount: ($selectorRules | length),
        selectorRuleBoundaryMissing: ($selectorRules | map(select((.sourceScope | scope_boundary_ok) and (.destinationScope | scope_boundary_ok) and (.candidateEgress | scope_boundary_ok) | not)) | length),
        providerRuleCount: ($providerRules | length),
        overlayRuleCount: ($overlayRules | length),
        dnsAllowCount: ($dnsAllows | length),
        dnsDenyCount: ($dnsDenies | length),
        dnsCollapsedCount: ($dnsCollapsed | length),
        invalidVirtualSample: ($virtual | map(select(has_boundary | not))[:3] | map({target, role, logicalInterface, adapterClass, sourceKind, runtimeInterface, runtimeIfName, boundaryIdentity, sourceScopeAuthority, hygieneDecision, spoofing, hygieneBoundary})),
        ok:
          ($virtual | length > 0)
          and (($selector | length) > 0)
          and (($overlayVpn | length) > 0)
          and all($virtual[]; has_boundary and .hostFacing == false)
          and all($hostP2p[]; has_hygiene_fields | not)
          and all($hostTenant[]; has_hygiene_fields | not)
          and ($selectorRules | length > 0)
          and all($selectorRules[]; (.sourceScope | scope_boundary_ok) and (.destinationScope | scope_boundary_ok) and (.candidateEgress | scope_boundary_ok))
          and ($providerRules | length > 0)
          and ($overlayRules | length > 0)
          and ($dnsAllows | length > 0)
          and ($dnsDenies | length > 0)
          and (($dnsCollapsed | length) == 0)
      }
  ' "${input}" > "${summary}"

  if jq -e '.ok == true' "${summary}" >/dev/null; then
    return 0
  fi

  if [[ "${mode}" != "quiet" ]]; then
    echo "FAIL FS-305-HDS-010-SDS-010-SMS-010 ${inventory_label}: virtual adapter hygiene boundary contract was not met" >&2
    jq . "${summary}" >&2
  fi
  return 1
}

mutate_hygiene_boundary() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def hygiene_paths:
      del(.boundaryIdentity, .sourceScopeAuthority, .hygieneDecision, .spoofing, .hygieneBoundary);

    if $mutation == "missing-boundary-identity" then
      (.. | objects | select((.virtualAdapter? // false) == true)) |= del(.boundaryIdentity)
    elif $mutation == "runtime-authority" then
      (.. | objects | select((.virtualAdapter? // false) == true)) |= (
        hygiene_paths
        | .adapterClass = "runtime-name-heuristic"
        | .sourceKind = "overlay"
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

  if validate_hygiene_boundary "${input}" "${inventory}-${label}" quiet; then
    echo "FAIL FS-305-HDS-010-SDS-010-SMS-010 ${inventory} ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-305-HDS-010-SDS-010-SMS-010 ${inventory} ${label}: seeded violation rejected"
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

for case in "nixos:${nixos_output}" "clab:${clab_output}"; do
  inventory="${case%%:*}"
  output="${case#*:}"

  validate_hygiene_boundary "${output}" "${inventory}"

  missing_boundary="${tmp_dir}/${inventory}.missing-boundary-identity.json"
  runtime_authority="${tmp_dir}/${inventory}.runtime-authority.json"

  mutate_hygiene_boundary "${output}" "${missing_boundary}" "missing-boundary-identity"
  mutate_hygiene_boundary "${output}" "${runtime_authority}" "runtime-authority"

  assert_rejects "${missing_boundary}" "${inventory}" "missing-boundary-identity"
  assert_rejects "${runtime_authority}" "${inventory}" "runtime-authority"

  validate_hygiene_boundary "${output}" "${inventory}"
done

echo "PASS fs305-virtual-adapter-hygiene-boundary"
