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

require_cmd git
require_cmd jq
require_cmd nix

labs_path="${NETWORK_LABS_PATH:-/home/deadbeef/github/network-labs}"
expected_labs_rev="c783759618a5bb751b497a4ebae210372d966bc5"
actual_labs_rev="$(git -C "${labs_path}" rev-parse HEAD)"

if [[ "${actual_labs_rev}" != "${expected_labs_rev}" ]]; then
  echo "FAIL: expected network-labs ${expected_labs_rev}, got ${actual_labs_rev} at ${labs_path}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

intent_path="${labs_path}/HAT/emulated-isp-residential-testnet/intent.nix"
nixos_output="${tmp_dir}/nixos-cpm.json"
clab_output="${tmp_dir}/clab-cpm.json"

nix run \
  --no-write-lock-file \
  --extra-experimental-features 'nix-command flakes' \
  "${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${labs_path}/HAT/emulated-isp-residential-testnet/inventory-nixos.nix" \
  "${nixos_output}" >/dev/null

nix run \
  --no-write-lock-file \
  --extra-experimental-features 'nix-command flakes' \
  "${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${labs_path}/HAT/emulated-isp-residential-testnet/inventory-clab.nix" \
  "${clab_output}" >/dev/null

jq -e '
  def iface($site; $target; $name):
    .control_plane_model.data.esp0xdeadbeef[$site].runtimeTargets[$target].effectiveRuntimeRealization.interfaces[$name];

  def assert_overlay($site; $target; $name; $runtime; $provider; $addr4; $addr6):
    iface($site; $target; $name) as $iface
    | $iface.sourceKind == "overlay"
      and $iface.adapterClass == "vpn"
      and $iface.virtualAdapter == true
      and $iface.hostFacing == false
      and $iface.exclusionReason == "overlay-tunnel-adapter"
      and $iface.runtimeIfName == $runtime
      and $iface.renderedIfName == $runtime
      and $iface.provider == $provider
      and $iface.overlay == ($name | sub("^overlay-"; ""))
      and $iface.addr4 == $addr4
      and $iface.addr6 == $addr6;

  def assert_underlay_p2p($site; $target):
    [
      .control_plane_model.data.esp0xdeadbeef[$site].runtimeTargets[$target].effectiveRuntimeRealization.interfaces
      | to_entries[]
      | select(.key | startswith("p2p-"))
      | select(.value.sourceKind != "p2p" or .value.adapterClass != "p2p-realization" or .value.virtualAdapter != false)
    ] | length == 0;

  assert_overlay("site-a"; "esp0xdeadbeef-site-a-nixos-core-nebula"; "overlay-nebula-egress"; "nebula1"; "nebula"; "100.96.44.1/32"; "fd42:dead:beef:9644::1/128")
  and assert_overlay("site-a"; "esp0xdeadbeef-site-a-nixos-core-wireguard-remote-egress"; "overlay-wireguard-egress"; "wg-egress"; "wireguard"; "10.66.44.1/32"; "fd42:dead:beef:6644::1/128")
  and assert_overlay("site-a"; "esp0xdeadbeef-site-a-nixos-core-wireguard-host128"; "overlay-wireguard-host128"; "wg-host128"; "wireguard"; "10.66.128.1/32"; "2001:db8:128::1/128")
  and assert_underlay_p2p("site-a"; "esp0xdeadbeef-site-a-nixos-core-nebula")
  and assert_underlay_p2p("site-a"; "esp0xdeadbeef-site-a-nixos-core-wireguard-remote-egress")
  and assert_underlay_p2p("site-a"; "esp0xdeadbeef-site-a-nixos-core-wireguard-host128")
' "${nixos_output}" >/dev/null

jq -e '
  def iface($site; $target; $name):
    .control_plane_model.data.esp0xdeadbeef[$site].runtimeTargets[$target].effectiveRuntimeRealization.interfaces[$name];

  def assert_overlay($site; $target; $name; $runtime; $provider; $addr4; $addr6):
    iface($site; $target; $name) as $iface
    | $iface.sourceKind == "overlay"
      and $iface.adapterClass == "vpn"
      and $iface.virtualAdapter == true
      and $iface.hostFacing == false
      and $iface.exclusionReason == "overlay-tunnel-adapter"
      and $iface.runtimeIfName == $runtime
      and $iface.renderedIfName == $runtime
      and $iface.provider == $provider
      and $iface.overlay == ($name | sub("^overlay-"; ""))
      and $iface.addr4 == $addr4
      and $iface.addr6 == $addr6;

  def assert_underlay_p2p($site; $target):
    [
      .control_plane_model.data.esp0xdeadbeef[$site].runtimeTargets[$target].effectiveRuntimeRealization.interfaces
      | to_entries[]
      | select(.key | startswith("p2p-"))
      | select(.value.sourceKind != "p2p" or .value.adapterClass != "p2p-realization" or .value.virtualAdapter != false)
    ] | length == 0;

  assert_overlay("site-b"; "esp0xdeadbeef-site-b-clab-core-nebula"; "overlay-nebula-egress"; "nebula1"; "nebula"; "100.97.44.1/32"; "fd42:dead:feed:9744::1/128")
  and assert_overlay("site-b"; "esp0xdeadbeef-site-b-clab-core-wireguard-remote-egress"; "overlay-wireguard-egress"; "wg-egress"; "wireguard"; "10.67.44.1/32"; "fd42:dead:feed:6744::1/128")
  and assert_overlay("site-b"; "esp0xdeadbeef-site-b-clab-core-wireguard-host128"; "overlay-wireguard-host128"; "wg-host128"; "wireguard"; "10.66.128.2/32"; "2001:db8:128::2/128")
  and assert_underlay_p2p("site-b"; "esp0xdeadbeef-site-b-clab-core-nebula")
  and assert_underlay_p2p("site-b"; "esp0xdeadbeef-site-b-clab-core-wireguard-remote-egress")
  and assert_underlay_p2p("site-b"; "esp0xdeadbeef-site-b-clab-core-wireguard-host128")
' "${clab_output}" >/dev/null

echo "PASS fs267-hat-overlay-runtime-adapter-consumption"
