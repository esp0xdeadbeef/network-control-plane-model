#!/usr/bin/env bash
# GAMP-ID: FS-267-HDS-010-SDS-010-SMS-010
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
      badHostP2pCount: ($badHostP2p | length),
      badHostTenantCount: ($badHostTenant | length)
    }
  | select(
      .virtualCount == 82
      and .selectorFabricLinkCount == 68
      and .providerSessionCount == 8
      and .overlayVpnCount == 6
      and .providerClientRuntimeAdapters == 4
      and .providerServerImplementations == 4
      and .hostFacingInterfaceCount == 108
      and .ambiguousVirtualCount == 0
      and .badSelectorCount == 0
      and .badProviderCount == 0
      and .badOverlayVpnCount == 0
      and .unexpectedVirtualCount == 0
      and .badHostP2pCount == 0
      and .badHostTenantCount == 0
    )
' "${output_json}" >/dev/null

echo "PASS fs267-virtual-adapter-taxonomy"
