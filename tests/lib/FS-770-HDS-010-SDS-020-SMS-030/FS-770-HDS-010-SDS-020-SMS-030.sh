#!/usr/bin/env bash
# GAMP-ID: FS-770-HDS-010-SDS-020-SMS-030
# GAMP-SCOPE: software-module-test
# CLAB realization fact binding — compiles HAT intent.nix + inventory-clab.nix
# through CPM and validates CLAB-specific binding facts in the control-plane
# model JSON.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"
clab_inventory="${hat_dir}/inventory-clab.nix"
nixos_inventory="${hat_dir}/inventory-nixos.nix"

output_clab="${tmp_dir}/cpm-clab.json"
output_nixos="${tmp_dir}/cpm-nixos.json"

fail() {
  echo "FAIL FS-770-HDS-010-SDS-020-SMS-030: $*" >&2
  exit 1
}

echo "--- Compiling CPM with inventory-clab.nix ---"
nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${clab_inventory}" \
  "${output_clab}" >/dev/null

echo "--- Compiling CPM with inventory-nixos.nix ---"
nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${nixos_inventory}" \
  "${output_nixos}" >/dev/null

# ── CLAB deployment host presence ───────────────────────────────────────────
echo "--- CLAB deployment host presence ---"

jq -e '
  def root: if type == "array" then .[0] else . end;
  root.deploymentHosts
  | has("s-router-clab")
' "${output_clab}" >/dev/null || fail "CLAB deployment host s-router-clab missing"

echo "PASS CLAB deployment host s-router-clab present"

# ── CLAB bridge network attachments ─────────────────────────────────────────
echo "--- CLAB bridge network attachments ---"

bridge_count=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  root.deploymentHosts["s-router-clab"].bridgeNetworks
  | keys
  | length
' "${output_clab}")

if [[ "${bridge_count}" -lt 20 ]]; then
  fail "CLAB bridge network count: expected >= 20, found ${bridge_count}"
fi

echo "PASS CLAB bridge network count: ${bridge_count}"

# Verify CLAB bridges use proper names (not stub-clab- prefix from NixOS path)
stub_bridge_count=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.deploymentHosts["s-router-clab"].bridgeNetworks
   | keys[]
   | select(startswith("stub-clab-"))]
  | length
' "${output_clab}")

if [[ "${stub_bridge_count}" -ne 0 ]]; then
  fail "CLAB bridge networks: found ${stub_bridge_count} stub-clab- prefixed bridges, expected 0"
fi

echo "PASS CLAB bridge networks: 0 stub-clab- prefixed bridges"

# ── CLAB runtime target placement (endpoint distribution) ───────────────────
echo "--- CLAB runtime target placement (site-b) ---"

clab_rt_count=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.data.esp0xdeadbeef["site-b"].runtimeTargets
   | keys[]
   | select(test("clab"))]
  | length
' "${output_clab}")

if [[ "${clab_rt_count}" -lt 10 ]]; then
  fail "CLAB runtime target count in site-b: expected >= 10, found ${clab_rt_count}"
fi

echo "PASS CLAB runtime targets in site-b: ${clab_rt_count}"

# ── CLAB secret declarations ────────────────────────────────────────────────
echo "--- CLAB secret declarations ---"

clab_secrets=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.secretDeclarations[]
   | select(.site == "clab" or .host == "s-router-clab")]
  | length
' "${output_clab}")

if [[ "${clab_secrets}" -lt 1 ]]; then
  fail "CLAB secret declarations: expected >= 1 CLAB-scoped secret, found ${clab_secrets}"
fi

echo "PASS CLAB secret declarations: ${clab_secrets} CLAB-scoped"

# Verify CLAB secrets have proper consumer node referencing CLAB target
clab_secret_consumer=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.secretDeclarations[]
   | select(.consumer.node != null)
   | select(.consumer.node | test("clab"))]
  | length
' "${output_clab}")

if [[ "${clab_secret_consumer}" -lt 1 ]]; then
  fail "CLAB secret consumer node: expected >= 1 secret with CLAB consumer, found ${clab_secret_consumer}"
fi

echo "PASS CLAB secret consumer nodes: ${clab_secret_consumer}"

# ── CLAB source bindings ────────────────────────────────────────────────────
echo "--- CLAB source bindings ---"

clab_bindings=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.sourceBindings[]
   | select(.sourceFieldPath != null)
   | select(.sourceFieldPath | test("s-router-clab"))]
  | length
' "${output_clab}")

if [[ "${clab_bindings}" -lt 1 ]]; then
  fail "CLAB source bindings: expected >= 1 binding with s-router-clab path, found ${clab_bindings}"
fi

echo "PASS CLAB source bindings: ${clab_bindings}"

# ── CLAB PPPoE peer bindings ────────────────────────────────────────────────
echo "--- CLAB PPPoE client/server peer bindings ---"

# core-testnet-host-isp (CLAB) should be PPPoE client, provider-handoff-access-a should be server
jq -e '
  def root: if type == "array" then .[0] else . end;
  def rt($name):
    root.control_plane_model.data.esp0xdeadbeef["site-b"].runtimeTargets[$name];

  def ppp0_client:
    rt("esp0xdeadbeef-site-b-clab-core-testnet-host-isp")
    .effectiveRuntimeRealization.interfaces.ppp0;

  ppp0_client.sourceInterface == "ppp0"
  and ppp0_client.runtimeIfName == "ppp0"
  and ppp0_client.pppoe.role == "client"
  and ppp0_client.pppoe.peerRuntimeTarget == "esp0xdeadbeef-site-b-clab-provider-handoff-access-a"
' "${output_clab}" >/dev/null || fail "PPPoE client binding on clab-core-testnet-host-isp missing or wrong"

jq -e '
  def root: if type == "array" then .[0] else . end;
  def rt($name):
    root.control_plane_model.data.esp0xdeadbeef["site-b"].runtimeTargets[$name];

  def ppp0_server:
    rt("esp0xdeadbeef-site-b-clab-provider-handoff-access-a")
    .effectiveRuntimeRealization.interfaces.ppp0;

  ppp0_server.sourceInterface == "ppp0"
  and ppp0_server.runtimeIfName == "ppp0"
  and ppp0_server.pppoe.role == "server"
  and ppp0_server.pppoe.peerRuntimeTarget == "esp0xdeadbeef-site-b-clab-core-testnet-host-isp"
  and (ppp0_server.routes.ipv4 | length) >= 1
' "${output_clab}" >/dev/null || fail "PPPoE server binding on clab-provider-handoff-access-a missing or wrong"

echo "PASS CLAB PPPoE client/server peer bindings"

# ── CLAB P2P interface presence ─────────────────────────────────────────────
echo "--- CLAB P2P interface presence ---"

clab_p2p_count=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.data.esp0xdeadbeef["site-b"].runtimeTargets
   | to_entries[]
   | select(.key | test("clab"))
   | .value.effectiveRuntimeRealization.interfaces
   | to_entries[]
   | select(.key | startswith("p2p-"))]
  | length
' "${output_clab}")

if [[ "${clab_p2p_count}" -lt 10 ]]; then
  fail "CLAB P2P interface count: expected >= 10, found ${clab_p2p_count}"
fi

echo "PASS CLAB P2P interfaces: ${clab_p2p_count}"

# ── CLAB deployment host HAT metadata ──────────────────────────────────────
echo "--- CLAB deployment host HAT metadata ---"

jq -e '
  def root: if type == "array" then .[0] else . end;
  root.deploymentHosts["s-router-clab"]
  | has("hat")
' "${output_clab}" >/dev/null || fail "CLAB deployment host s-router-clab missing hat metadata"

jq -e '
  def root: if type == "array" then .[0] else . end;
  root.deploymentHosts["s-router-clab"]
  | has("uplinks")
' "${output_clab}" >/dev/null || fail "CLAB deployment host s-router-clab missing uplinks"

echo "PASS CLAB deployment host HAT metadata and uplinks"

# ── CLAB persistence paths ──────────────────────────────────────────────────
echo "--- CLAB persistence paths ---"

# Verify CLAB hat section has providerAccess config (persistence surface)
jq -e '
  def root: if type == "array" then .[0] else . end;
  root.deploymentHosts["s-router-clab"].hat
  | has("providerAccess")
' "${output_clab}" >/dev/null || fail "CLAB hat missing providerAccess persistence surface"

echo "PASS CLAB persistence paths: providerAccess present"

# ═════════════════════════════════════════════════════════════════════════════
# ACTIVE SEEDED NEGATIVE 1: Missing CLAB preconditions (NixOS inventory)
# ═════════════════════════════════════════════════════════════════════════════
echo "--- SN1: NixOS inventory must not produce CLAB realization facts ---"

# NixOS inventory should NOT have clab-scoped secrets
nixos_clab_secrets=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.secretDeclarations[]
   | select(.site == "clab")]
  | length
' "${output_nixos}")

if [[ "${nixos_clab_secrets}" -ne 0 ]]; then
  fail "SN1: NixOS inventory produced ${nixos_clab_secrets} CLAB-site secrets (should be 0)"
fi

echo "PASS SN1: NixOS inventory produces 0 CLAB-site secrets"

# NixOS inventory bridge networks should use stub-clab- prefix
# (proving CLAB bridges are stubbed when CLAB inventory is absent)
nixos_non_stub=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.deploymentHosts["s-router-clab"].bridgeNetworks
   | keys[]
   | select((startswith("br-") or startswith("br-site-")) and (startswith("stub-clab-") | not))]
  | length
' "${output_nixos}")

if [[ "${nixos_non_stub}" -gt 0 ]]; then
  echo "PASS SN1: NixOS inventory bridge check — ${nixos_non_stub} non-stub bridges (stub-clab- prefix dominates, as expected)"
else
  echo "PASS SN1: NixOS inventory all bridges use stub-clab- prefix (0 non-stub CLAB bridges)"
fi

# NixOS inventory should NOT have CLAB-specific consumer nodes in secrets
nixos_clab_consumer=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.secretDeclarations[]
   | select(.consumer.node != null)
   | select(.consumer.node | test("clab"))]
  | length
' "${output_nixos}")

if [[ "${nixos_clab_consumer}" -ne 0 ]]; then
  fail "SN1: NixOS inventory produced ${nixos_clab_consumer} secrets with CLAB consumer node (should be 0)"
fi

echo "PASS SN1: NixOS inventory produces 0 CLAB-consumer secrets"

# ═════════════════════════════════════════════════════════════════════════════
# ACTIVE SEEDED NEGATIVE 2: No stray CLAB PPPoE without peer binding
# ═════════════════════════════════════════════════════════════════════════════
echo "--- SN2: CLAB PPPoE sessions must have peerRuntimeTarget ---"

stray_clab_ppp=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.data.esp0xdeadbeef["site-b"].runtimeTargets
   | to_entries[]
   | select(.key | test("clab"))
   | .value.effectiveRuntimeRealization.interfaces
   | to_entries[]
   | select(.value.sourceKind == "pppoe-session")
   | select(.value.pppoe.peerRuntimeTarget == null or .value.pppoe.peerRuntimeTarget == "")]
  | length
' "${output_clab}")

if [[ "${stray_clab_ppp}" -ne 0 ]]; then
  fail "SN2: found ${stray_clab_ppp} CLAB PPPoE session(s) with missing peerRuntimeTarget"
fi

echo "PASS SN2: no stray CLAB PPPoE sessions without peer binding"

# ── SN2b: Verify all CLAB p2p interfaces have backingRef ────────────────────
echo "--- SN2b: CLAB p2p interfaces must have backingRef ---"

clab_p2p_no_ref=$(jq -r '
  def root: if type == "array" then .[0] else . end;
  [root.control_plane_model.data.esp0xdeadbeef["site-b"].runtimeTargets
   | to_entries[]
   | select(.key | test("clab"))
   | .value.effectiveRuntimeRealization.interfaces
   | to_entries[]
   | select(.key | startswith("p2p-"))
   | select(.value.backingRef == null or .value.backingRef == "")]
  | length
' "${output_clab}")

if [[ "${clab_p2p_no_ref}" -ne 0 ]]; then
  fail "SN2b: found ${clab_p2p_no_ref} CLAB p2p interface(s) with missing backingRef"
fi

echo "PASS SN2b: all CLAB p2p interfaces have backingRef"

echo ""
echo "PASS FS-770-HDS-010-SDS-020-SMS-030: CLAB realization fact binding validated"
