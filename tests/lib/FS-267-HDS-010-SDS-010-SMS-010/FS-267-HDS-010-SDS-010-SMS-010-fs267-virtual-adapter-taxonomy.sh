#!/usr/bin/env bash
# GAMP-ID: FS-267-HDS-010-SDS-010-SMS-010
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
output_json="${tmp_dir}/cpm.json"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"

nix run \
  --no-write-lock-file \
  --extra-experimental-features 'nix-command flakes' \
  "${repo_root}#compile-and-build-control-plane-model" -- \
  "${hat_dir}/intent.nix" \
  "${hat_dir}/inventory-nixos.nix" \
  "${output_json}" >/dev/null

validate_taxonomy() {
  local input="$1"

  jq -e '
  def interfaces:
    [
      .control_plane_model.data
      | to_entries[] as $enterprise
      | $enterprise.value
      | to_entries[] as $site
      | $site.value.runtimeTargets
      | to_entries[] as $target
      | (($target.value.effectiveRuntimeRealization.interfaces // {}) | to_entries[]?)
      | .value
        + {
            target: $target.key,
            logicalInterface: .key,
            role: ($target.value.role // "")
          }
    ];

  interfaces as $interfaces
  | ($interfaces | map(select(.virtualAdapter == true))) as $virtual
  | ($interfaces | map(select(.adapterClass == "selector-fabric-link"))) as $selector
  | ($interfaces | map(select(.adapterClass == "provider-session"))) as $provider
  | ($interfaces | map(select(.sourceKind == "overlay" and .adapterClass == "vpn"))) as $overlayVpn
  | ($interfaces | map(select(.sourceKind == "p2p" and .virtualAdapter == false))) as $hostP2p
  | ($interfaces | map(select(.sourceKind == "tenant" and .virtualAdapter == false))) as $hostTenant
  | [
      $virtual[]
      | select(
          ((.adapterClass // "") == "")
          or ((.owningRole // "") == "")
          or (.hostFacing != false)
          or ((.exclusionReason // "") == "")
        )
    ] as $ambiguousVirtual
  | [
      $selector[]
      | select(
          .virtualAdapter != true
          or .hostFacing != false
          or .exclusionReason != "selector-fabric-link"
          or .p2pPurpose != "selector-fabric"
          or (.fabricLink.transport.hostFacing != false)
          or (((.fabricLink.link // "")) != ((.backingRef.name // "")))
        )
    ] as $badSelector
  | [
      $provider[]
      | select(
          .virtualAdapter != true
          or .hostFacing != false
          or .exclusionReason != "provider-session-virtual-adapter"
          or .service != "pppoe"
          or .sessionPurpose != "provider-access"
          or ((.serviceRole // "") != "client" and (.serviceRole // "") != "server")
        )
    ] as $badProvider
  | [
      $overlayVpn[]
      | select(
          .virtualAdapter != true
          or .hostFacing != false
          or .exclusionReason != "overlay-tunnel-adapter"
          or .tunnelPurpose != "overlay-reachability"
          or ((.runtimeIfName // "") == "")
          or ((.renderedIfName // "") != (.runtimeIfName // ""))
          or ((.provider // "") != "nebula" and (.provider // "") != "wireguard")
          or ((.overlay // "") == "")
        )
    ] as $badOverlayVpn
  | [
      $virtual[]
      | select(
          (.adapterClass != "selector-fabric-link")
          and (.adapterClass != "provider-session")
          and ((.sourceKind == "overlay" and .adapterClass == "vpn") | not)
        )
    ] as $unexpectedVirtual
  | [
      $virtual[]
      | select(.hostFacing != false)
    ] as $badVirtualHostFacing
  | [
      $interfaces[]
      | select(
          (.hostFacing == true)
          and ((.runtimeIfName // "") | test("^(ppp|wg|nebula)"))
          and (.virtualAdapter != true)
          and (((.adapterClass // "") == "runtime-name-heuristic") or ((.sourceKind // "") == "overlay"))
        )
    ] as $badRuntimeNameAuthority
  | [
      $hostP2p[]
      | select(
          .adapterClass != "p2p-realization"
          or .hostFacing != true
          or ((.owningRole // "") == "")
        )
    ] as $badHostP2p
  | [
      $hostTenant[]
      | select(
          .adapterClass != "tenant-role-surface"
          or .hostFacing != true
          or ((.owningRole // "") == "")
        )
    ] as $badHostTenant
  | {
      virtualCount: ($virtual | length),
      selectorFabricLinkCount: ($selector | length),
      providerSessionCount: ($provider | length),
      overlayVpnCount: ($overlayVpn | length),
      providerClientRuntimeAdapters: ($provider | map(select(.serviceRole == "client" and ((.runtimeAdapter // "") | test("^ppp[0-9]+$")))) | length),
      providerServerImplementations: ($provider | map(select(.serviceRole == "server" and .implementation == "rp-pppoe")) | length),
      hostFacingInterfaceCount: ($interfaces | map(select(.hostFacing == true)) | length),
      ambiguousVirtualCount: ($ambiguousVirtual | length),
      badSelectorCount: ($badSelector | length),
      badProviderCount: ($badProvider | length),
      badOverlayVpnCount: ($badOverlayVpn | length),
      unexpectedVirtualCount: ($unexpectedVirtual | length),
      badVirtualHostFacingCount: ($badVirtualHostFacing | length),
      badRuntimeNameAuthorityCount: ($badRuntimeNameAuthority | length),
      badHostP2pCount: ($badHostP2p | length),
      badHostTenantCount: ($badHostTenant | length)
    }
  | select(
      .virtualCount > 0
      and .selectorFabricLinkCount > 0
      and .overlayVpnCount > 0
      and .hostFacingInterfaceCount > 0
      and .ambiguousVirtualCount == 0
      and .badSelectorCount == 0
      and .badProviderCount == 0
      and .badOverlayVpnCount == 0
      and .unexpectedVirtualCount == 0
      and .badVirtualHostFacingCount == 0
      and .badRuntimeNameAuthorityCount == 0
      and .badHostP2pCount == 0
      and .badHostTenantCount == 0
    )
  ' "${input}" >/dev/null
}

mutate_first_virtual() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def first_virtual_ids:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | (($target.value.effectiveRuntimeRealization.interfaces // {}) | to_entries[]?)
        | select(.value.virtualAdapter == true)
        | [$enterprise.key, $site.key, $target.key, .key]
      ][0];

    first_virtual_ids as $ids
    | ["control_plane_model", "data", $ids[0], $ids[1], "runtimeTargets", $ids[2], "effectiveRuntimeRealization", "interfaces", $ids[3]] as $p
    | if $mutation == "host-facing" then
        setpath($p + ["hostFacing"]; true)
      elif $mutation == "missing-exclusion" then
        delpaths([$p + ["exclusionReason"]])
      elif $mutation == "runtime-name-authority" then
        setpath($p + ["hostFacing"]; true)
        | setpath($p + ["virtualAdapter"]; false)
        | setpath($p + ["adapterClass"]; "runtime-name-heuristic")
        | setpath($p + ["runtimeIfName"]; "ppp0")
        | setpath($p + ["renderedIfName"]; "ppp0")
      else
        .
      end
  ' "${input}" > "${output}"
}

assert_rejects() {
  local input="$1"
  local label="$2"

  if validate_taxonomy "${input}"; then
    echo "FAIL FS-267-HDS-010-SDS-010-SMS-010 ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-267-HDS-010-SDS-010-SMS-010 ${label}: seeded violation rejected"
}

validate_taxonomy "${output_json}"

host_facing_negative="${tmp_dir}/host-facing-negative.json"
missing_exclusion_negative="${tmp_dir}/missing-exclusion-negative.json"
runtime_name_negative="${tmp_dir}/runtime-name-negative.json"

mutate_first_virtual "${output_json}" "${host_facing_negative}" "host-facing"
mutate_first_virtual "${output_json}" "${missing_exclusion_negative}" "missing-exclusion"
mutate_first_virtual "${output_json}" "${runtime_name_negative}" "runtime-name-authority"

assert_rejects "${host_facing_negative}" "virtual-host-facing"
assert_rejects "${missing_exclusion_negative}" "missing-exclusion-reason"
assert_rejects "${runtime_name_negative}" "runtime-name-authority"

echo "PASS fs267-virtual-adapter-taxonomy"
