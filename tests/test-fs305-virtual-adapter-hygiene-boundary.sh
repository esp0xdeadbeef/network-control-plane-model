#!/usr/bin/env bash
# GAMP-ID: FS-305-HDS-010-SDS-010-SMS-010
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
trap 'rm -rf "${tmp_dir}"' EXIT

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_path="$(jq -er '.inputs["network-labs"].path' "${archive_json}")"

for inventory in nixos clab; do
  output_json="${tmp_dir}/hat-${inventory}-cpm.json"

  nix run \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "${repo_root}#compile-and-build-control-plane-model" -- \
    "${labs_path}/HAT/emulated-isp-residential-testnet/intent.nix" \
    "${labs_path}/HAT/emulated-isp-residential-testnet/inventory-${inventory}.nix" \
    "${output_json}" >/dev/null

  jq -e --arg inventory "${inventory}" '
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
        | .value + { target: $target.target, site: $target.site, logicalInterface: .key, role: ($target.role // "") }
      ];

    def rules:
      [
        targets[] as $target
        | ($target.forwardingIntent.rules // [])[]?
        | . + { target: $target.target, site: $target.site, role: ($target.role // "") }
      ];

    def has_boundary:
      (.boundaryIdentity.kind == "virtual-adapter-hygiene-boundary")
      and ((.boundaryIdentity.adapterClass // "") == (.adapterClass // ""))
      and (.sourceScopeAuthority.authority == "control-plane-model")
      and (.sourceScopeAuthority.failClosedWhenAbsent == true)
      and (.hygieneDecision.enforcement == "fail-closed")
      and (.hygieneDecision.interfaceTupleOnlyAuthority == false)
      and (.spoofing.rejection == "fail-closed")
      and (.spoofing.interfaceTupleOnlyBypass == false)
      and (.hygieneBoundary.provenance.route.gate == "route-intent-and-policy-only-classification")
      and (.hygieneBoundary.provenance.firewall.gate == "relation-handoff")
      and (.hygieneBoundary.provenance.nat.gate == "route-safety")
      and (.hygieneBoundary.provenance.providerEgress.gate == "provider-egress-source");

    def scope_has_boundary:
      (.boundaryIdentity.kind == "virtual-adapter-hygiene-boundary")
      and (.sourceScopeAuthority.authority == "control-plane-model")
      and (.hygieneDecision.enforcement == "fail-closed")
      and (.spoofing.rejection == "fail-closed");

    def scope_boundary_ok:
      if (.virtualAdapter // false) == true then
        scope_has_boundary
      else
        (has("boundaryIdentity") or has("sourceScopeAuthority") or has("hygieneDecision") or has("spoofing") or has("hygieneBoundary")) | not
      end;

    def source_key:
      [ (.sourcePrefixes // [])[]? | { family: (.family // null), prefix: (.prefix // "") } ]
      | sort_by(.family // 0, .prefix);

    interfaces as $ifaces
    | rules as $rules
    | ($ifaces | map(select(.adapterClass == "provider-session"))) as $provider
    | ($ifaces | map(select(.adapterClass == "selector-fabric-link"))) as $selector
    | ($ifaces | map(select(.sourceKind == "overlay" and .adapterClass == "vpn"))) as $overlayVpn
    | ($ifaces | map(select(.sourceKind == "p2p" and .hostFacing == true))) as $hostP2p
    | ($ifaces | map(select(.sourceKind == "tenant" and .hostFacing == true))) as $hostTenant
    | ($rules | map(select((.relationId // "") | startswith("selector-handoff-")))) as $selectorRules
    | ($rules | map(select(.relationId == "allow-provider-handoff-a-to-isp-a" or .relationId == "allow-provider-handoff-b-to-isp-a"))) as $providerRules
    | ($rules | map(select(.relationId == "allow-iot-underlay-to-nebula-egress" or .relationId == "allow-iot-underlay-to-wireguard-egress"))) as $overlayRules
    | ($rules | map(select(.relationId == "allow-hat-site-dns-service-to-client-uplinks"))) as $dnsAllows
    | ($rules | map(select(.relationId == "deny-client-dns-to-uplinks"))) as $dnsDenies
    | {
        inventory: $inventory,
        providerSessionCount: ($provider | length),
        selectorFabricLinkCount: ($selector | length),
        overlayVpnCount: ($overlayVpn | length),
        providerMissing: ($provider | map(select(has_boundary | not)) | length),
        selectorMissing: ($selector | map(select(has_boundary | not)) | length),
        overlayMissing: ($overlayVpn | map(select(has_boundary | not)) | length),
        hostP2pPromoted: ($hostP2p | map(select(has("boundaryIdentity") or has("sourceScopeAuthority") or has("hygieneDecision") or has("spoofing") or has("hygieneBoundary"))) | length),
        hostTenantPromoted: ($hostTenant | map(select(has("boundaryIdentity") or has("sourceScopeAuthority") or has("hygieneDecision") or has("spoofing") or has("hygieneBoundary"))) | length),
        selectorRuleCount: ($selectorRules | length),
        selectorRuleBoundaryMissing: ($selectorRules | map(select((.sourceScope | scope_boundary_ok) and (.destinationScope | scope_boundary_ok) and (.candidateEgress | scope_boundary_ok) | not)) | length),
        providerRuleCount: ($providerRules | length),
        overlayRuleCount: ($overlayRules | length),
        dnsAllowCount: ($dnsAllows | length),
        dnsDenyCount: ($dnsDenies | length),
        dnsCollapsed: (
          [
            $dnsAllows[] as $allow
            | $dnsDenies[] as $deny
            | select(
                $allow.fromInterface == $deny.fromInterface
                and $allow.toInterface == $deny.toInterface
                and $allow.trafficType == $deny.trafficType
                and (($allow.matches // []) == ($deny.matches // []))
                and (($allow | source_key) == ($deny | source_key))
              )
          ] | length
        ),
        ok:
          ($provider | length == 8)
          and ($selector | length == 68)
          and ($overlayVpn | length == 6)
          and all($provider[]; has_boundary and .boundaryIdentity.boundary == "provider-session" and .sourceScopeAuthority.sourceClass == "provider-session")
          and all($selector[]; has_boundary and .boundaryIdentity.boundary == "selector-fabric-link" and .sourceScopeAuthority.sourceClass == "selector-fabric-link")
          and all($overlayVpn[]; has_boundary and .boundaryIdentity.boundary == "overlay-vpn-adapter" and .sourceScopeAuthority.sourceClass == "overlay-runtime-adapter")
          and all($hostP2p[]; (has("boundaryIdentity") or has("sourceScopeAuthority") or has("hygieneDecision") or has("spoofing") or has("hygieneBoundary")) | not)
          and all($hostTenant[]; (has("boundaryIdentity") or has("sourceScopeAuthority") or has("hygieneDecision") or has("spoofing") or has("hygieneBoundary")) | not)
          and ($selectorRules | length == 236)
          and all($selectorRules[]; (.sourceScope | scope_boundary_ok) and (.destinationScope | scope_boundary_ok) and (.candidateEgress | scope_boundary_ok))
          and ($providerRules | length == 4)
          and ($overlayRules | length == 4)
          and ($dnsAllows | length == 4)
          and ($dnsDenies | length == 4)
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
    echo "FAIL fs305-virtual-adapter-hygiene-boundary (${inventory}): missing virtual adapter hygiene-boundary contract, false host-facing promotion, or DNS source identity collapse" >&2
    jq '
      def targets: [.control_plane_model.data|to_entries[]|.value|to_entries[]|.value.runtimeTargets|to_entries[]];
      def ifaces: [targets[] as $t | ($t.value.effectiveRuntimeRealization.interfaces // {}) | to_entries[]? | .value + {target:$t.key, logicalInterface:.key, role:($t.value.role // "")}];
      def rules: [targets[] as $t | ($t.value.forwardingIntent.rules // [])[]? | . + {target:$t.key, role:($t.value.role // "")}];
      ifaces as $ifaces | rules as $rules |
      {
        providerSessionCount: ($ifaces | map(select(.adapterClass == "provider-session")) | length),
        selectorFabricLinkCount: ($ifaces | map(select(.adapterClass == "selector-fabric-link")) | length),
        overlayVpnCount: ($ifaces | map(select(.sourceKind == "overlay" and .adapterClass == "vpn")) | length),
        boundaryIdentityCount: ($ifaces | map(select(has("boundaryIdentity"))) | length),
        sourceScopeAuthorityCount: ($ifaces | map(select(has("sourceScopeAuthority"))) | length),
        hygieneDecisionCount: ($ifaces | map(select(has("hygieneDecision"))) | length),
        spoofingCount: ($ifaces | map(select(has("spoofing"))) | length),
        hostFacingBoundaryCount: ($ifaces | map(select(.hostFacing == true and (has("boundaryIdentity") or has("sourceScopeAuthority") or has("hygieneDecision") or has("spoofing") or has("hygieneBoundary")))) | length),
        ruleBoundaryCount: ($rules | map(select((.sourceScope.boundaryIdentity.kind? // "") == "virtual-adapter-hygiene-boundary" or (.destinationScope.boundaryIdentity.kind? // "") == "virtual-adapter-hygiene-boundary" or (.candidateEgress.boundaryIdentity.kind? // "") == "virtual-adapter-hygiene-boundary")) | length),
        providerRules: ($rules | map(select(.relationId == "allow-provider-handoff-a-to-isp-a" or .relationId == "allow-provider-handoff-b-to-isp-a")) | length),
        overlayRules: ($rules | map(select(.relationId == "allow-iot-underlay-to-nebula-egress" or .relationId == "allow-iot-underlay-to-wireguard-egress")) | length),
        dnsRules: ($rules | map(select(.relationId == "allow-hat-site-dns-service-to-client-uplinks" or .relationId == "deny-client-dns-to-uplinks")) | length)
      }
    ' "${output_json}" >&2
    exit 1
  }
done

echo "PASS fs305-virtual-adapter-hygiene-boundary"
