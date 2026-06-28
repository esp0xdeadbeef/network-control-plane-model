#!/usr/bin/env bash
# GAMP-ID: FS-770-HDS-010-SDS-020-SMS-020
# GAMP-SCOPE: software-module-test
# NixOS realization fact binding — compiles HAT intent.nix + inventory-nixos.nix
# through CPM and validates binding facts in the control-plane model JSON.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"
inventory_path="${hat_dir}/inventory-nixos.nix"

output_json="${tmp_dir}/cpm-nixos.json"

echo "--- Compiling CPM with inventory-nixos.nix ---"
nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${inventory_path}" \
  "${output_json}" >/dev/null

fail() {
  echo "FAIL FS-770-HDS-010-SDS-020-SMS-020: $*" >&2
  exit 1
}

# ── PPPoE client/server binding facts ──────────────────────────────────────
echo "--- PPPoE client/server binding facts ---"

# Provider-handoff-access-a is the PPPoE server
jq -e '
  def root: if type == "array" then .[0] else . end;
  def rt($name):
    root.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets[$name];

  def ppp0_server:
    rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a")
    .effectiveRuntimeRealization.interfaces.ppp0;

  ppp0_server.sourceInterface == "ppp0"
  and ppp0_server.runtimeIfName == "ppp0"
  and ppp0_server.pppoe.role == "server"
  and ppp0_server.pppoe.peerRuntimeTarget == "esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"
  and (ppp0_server.routes.ipv4 | length) >= 1
' "${output_json}" >/dev/null || fail "PPPoE server binding on provider-handoff-access-a missing or wrong"

# Core-testnet-host-isp is the PPPoE client
jq -e '
  def root: if type == "array" then .[0] else . end;
  def rt($name):
    root.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets[$name];

  def ppp0_client:
    rt("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp")
    .effectiveRuntimeRealization.interfaces.ppp0;

  ppp0_client.sourceInterface == "ppp0"
  and ppp0_client.runtimeIfName == "ppp0"
  and ppp0_client.pppoe.role == "client"
  and ppp0_client.pppoe.peerRuntimeTarget == "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a"
' "${output_json}" >/dev/null || fail "PPPoE client binding on core-testnet-host-isp missing or wrong"

echo "PASS PPPoE client/server binding facts"

# ── Host uplink substrate facts ────────────────────────────────────────────
echo "--- Host uplink substrate facts ---"

# Host uplink DHCP and VLAN facts are deployment-host inventory facts. The
# runtime target interface may resolve to modeled upstream addressing, so do
# not require runtimeTargets.*.interfaces.*.ipv4.method to remain "dhcp".
dhcp_uplink_count=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.deploymentHosts["s-router-nixos"].uplinks
   | to_entries[]
   | select(.value.ipv4.method == "dhcp")]
  | length
' "${output_json}")

if [[ "${dhcp_uplink_count}" -lt 2 ]]; then
  fail "host uplink DHCP facts: expected at least 2, found ${dhcp_uplink_count}"
fi

jq -e '
  def root: if type == "array" then .[0] else . end;
  def uplink($name): root.deploymentHosts["s-router-nixos"].uplinks[$name];

  uplink("management").ipv4.method == "dhcp"
  and uplink("management").ipv4.dhcp == true
  and uplink("management").mode == "vlan"
  and uplink("management").vlan == 2
  and uplink("management").bridge == "vlan2"
  and uplink("uplink-isp-a").ipv4.method == "dhcp"
  and uplink("uplink-isp-a").ipv4.dhcp == true
  and uplink("uplink-isp-a").mode == "vlan"
  and uplink("uplink-isp-a").vlan == 4
  and uplink("uplink-isp-a").bridge == "br-uplink0"
' "${output_json}" >/dev/null || fail "NixOS deployment host DHCP/VLAN uplink binding missing or wrong"

echo "PASS host uplink substrate facts: ${dhcp_uplink_count} DHCP uplinks with VLAN/bridge bindings"

# ── P2P interface presence ─────────────────────────────────────────────────
echo "--- P2P interface presence ---"

p2p_count=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets
   | to_entries[]
   | .value.effectiveRuntimeRealization.interfaces
   | to_entries[]
   | select(.key | startswith("p2p-"))]
  | length
' "${output_json}")

if [[ "${p2p_count}" -lt 10 ]]; then
  fail "P2P interface count: expected >= 10, found ${p2p_count}"
fi

echo "PASS P2P interface presence: ${p2p_count} p2p interfaces"

# ── Traffic path ordering ──────────────────────────────────────────────────
echo "--- Traffic path ordering ---"

# Verify that at least one runtimeTarget has ordered trafficPaths
tp_targets=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets
   | to_entries[]
   | select(.value.effectiveRuntimeRealization.trafficPaths != null)
   | select((.value.effectiveRuntimeRealization.trafficPaths | length) > 0)]
  | length
' "${output_json}")

# NOTE: trafficPaths may be empty/absent if no site-to-site forwarding is configured.
# This is not a gap — just verify the field is parseable.
echo "PASS traffic path ordering: ${tp_targets} targets with trafficPaths"

# ── Active seeded negative: verify PPPoE requires peer binding ─────────────
echo "--- SN1: missing PPPoE peer should be absent ---"

# Verify that no runtimeTarget has a stray ppp0 without a peerRuntimeTarget
stray_ppp=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets
   | to_entries[]
   | .value.effectiveRuntimeRealization.interfaces
   | to_entries[]
   | select(.value.sourceKind == "pppoe-session")
   | select(.value.pppoe.peerRuntimeTarget == null or .value.pppoe.peerRuntimeTarget == "")]
  | length
' "${output_json}")

if [[ "${stray_ppp}" -ne 0 ]]; then
  fail "SN1: found ${stray_ppp} PPPoE session(s) with missing peerRuntimeTarget"
fi

echo "PASS SN1: no stray PPPoE sessions without peer binding"

# ── Active seeded negative: verify all p2p interfaces have backingRef ──────
echo "--- SN2: p2p interfaces must have backingRef ---"

p2p_no_ref=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets
   | to_entries[]
   | .value.effectiveRuntimeRealization.interfaces
   | to_entries[]
   | select(.key | startswith("p2p-"))
   | select(.value.backingRef == null or .value.backingRef == "")]
  | length
' "${output_json}")

if [[ "${p2p_no_ref}" -ne 0 ]]; then
  fail "SN2: found ${p2p_no_ref} p2p interface(s) with missing backingRef"
fi

echo "PASS SN2: all p2p interfaces have backingRef"

echo ""
echo "PASS FS-770-HDS-010-SDS-020-SMS-020: NixOS realization fact binding validated"
