#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# Focused regression test: ALL provider-handoff containers (both PPPoE pairs,
# both substrates, IPv4+IPv6) must have default-reachability routes stripped
# from p2p interfaces to PPPoE client cores.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"

# Test NixOS substrate
echo "--- Testing NixOS substrate ---"
output_json="${tmp_dir}/cpm-nixos.json"
nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${hat_dir}/intent.nix" \
  "${hat_dir}/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -e '
  def root: if type == "array" then .[0] else . end;
  def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
  def rt($target): site.runtimeTargets[$target];

  def p2p_to_pppoe_core_has_no_default($target; $p2p_iface):
    rt($target).effectiveRuntimeRealization.interfaces[$p2p_iface] as $iface
    | ($iface | (.routes.ipv4 // []) | map(select(.intent.kind == "default-reachability"))) as $v4_defaults
    | ($iface | (.routes.ipv6 // []) | map(select(.intent.kind == "default-reachability"))) as $v6_defaults
    | ($v4_defaults == []) and ($v6_defaults == []);

  # Pair A (host-isp) - provider-handoff-access-a p2p to core-testnet-host-isp
  p2p_to_pppoe_core_has_no_default(
    "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a";
    "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a"
  )
  # Pair B (routed-isp) - provider-handoff-access-b p2p to core-testnet-routed-isp
  and p2p_to_pppoe_core_has_no_default(
    "esp0xdeadbeef-site-a-nixos-provider-handoff-access-b";
    "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b"
  )
  # Pair A PPPoE server session interface also has no default-reachability
  and ((rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a").effectiveRuntimeRealization.interfaces.ppp0.routes.ipv4
    | map(select(.intent.kind == "default-reachability"))) == [])
  # Pair B PPPoE server session interface also has no default-reachability
  and ((rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b").effectiveRuntimeRealization.interfaces.ppp1.routes.ipv4
    | map(select(.intent.kind == "default-reachability"))) == [])
' "${output_json}" >/dev/null
echo "PASS pppoe-provider-default-route-stripping nixos substrate"

# Test CLAB substrate
echo "--- Testing CLAB substrate ---"
output_json="${tmp_dir}/cpm-clab.json"
nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${hat_dir}/intent.nix" \
  "${hat_dir}/inventory-clab.nix" \
  "${output_json}" >/dev/null

jq -e '
  def root: if type == "array" then .[0] else . end;
  def site: root.control_plane_model.data.esp0xdeadbeef."site-b";
  def rt($target): site.runtimeTargets[$target];

  def p2p_to_pppoe_core_has_no_default($target; $p2p_iface):
    rt($target).effectiveRuntimeRealization.interfaces[$p2p_iface] as $iface
    | ($iface | (.routes.ipv4 // []) | map(select(.intent.kind == "default-reachability"))) as $v4_defaults
    | ($iface | (.routes.ipv6 // []) | map(select(.intent.kind == "default-reachability"))) as $v6_defaults
    | ($v4_defaults == []) and ($v6_defaults == []);

  # Pair A (host-isp) - CLAB provider-handoff-access-a p2p to core-testnet-host-isp
  p2p_to_pppoe_core_has_no_default(
    "esp0xdeadbeef-site-b-clab-provider-handoff-access-a";
    "p2p-clab-core-testnet-host-isp-clab-provider-handoff-access-a"
  )
  # Pair B (routed-isp) - CLAB provider-handoff-access-b p2p to core-testnet-routed-isp
  and p2p_to_pppoe_core_has_no_default(
    "esp0xdeadbeef-site-b-clab-provider-handoff-access-b";
    "p2p-clab-core-testnet-routed-isp-clab-provider-handoff-access-b"
  )
  # Pair A CLAB PPPoE server session interface also has no default-reachability
  and ((rt("esp0xdeadbeef-site-b-clab-provider-handoff-access-a").effectiveRuntimeRealization.interfaces.ppp0.routes.ipv4
    | map(select(.intent.kind == "default-reachability"))) == [])
  # Pair B CLAB PPPoE server session interface also has no default-reachability
  and ((rt("esp0xdeadbeef-site-b-clab-provider-handoff-access-b").effectiveRuntimeRealization.interfaces.ppp1.routes.ipv4
    | map(select(.intent.kind == "default-reachability"))) == [])
' "${output_json}" >/dev/null
echo "PASS pppoe-provider-default-route-stripping clab substrate"

echo "PASS test-pppoe-provider-default-route-stripping all substrates"
