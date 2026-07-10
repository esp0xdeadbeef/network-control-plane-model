#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
# Focused regression test: provider-handoff access nodes (both PPPoE pairs,
# both substrates) must have a default-reachability route on their p2p
# interface to the downstream-selector, and must NOT have any
# default-reachability route on PPPoE-linked p2p interfaces.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

  def has_default_via_ds($target; $p2p_iface; $expected_via4):
    rt($target).effectiveRuntimeRealization.interfaces[$p2p_iface] as $iface
    | ($iface.routes.ipv4 // []) as $v4
    | ($v4 | map(select(.intent.kind == "default-reachability"))) as $defaults
    | ($defaults | length) == 1
    and $defaults[0].proto == "default"
    and $defaults[0].via4 == $expected_via4;

  def no_default($target; $iface_name):
    rt($target).effectiveRuntimeRealization.interfaces[$iface_name] as $iface
    | (($iface.routes.ipv4 // []) | map(select(.intent.kind == "default-reachability")) | length) == 0;

  # Provider A: default via downstream-selector (10.10.44.58)
  has_default_via_ds(
    "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a";
    "p2p-nixos-downstream-selector-nixos-provider-handoff-access-a";
    "10.10.44.58"
  )
  # Provider A: NO default on PPPoE-linked p2p
  and no_default(
    "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a";
    "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a"
  )
  # Provider B: default via downstream-selector (10.10.44.60)
  and has_default_via_ds(
    "esp0xdeadbeef-site-a-nixos-provider-handoff-access-b";
    "p2p-nixos-downstream-selector-nixos-provider-handoff-access-b";
    "10.10.44.60"
  )
  # Provider B: NO default on PPPoE-linked p2p
  and no_default(
    "esp0xdeadbeef-site-a-nixos-provider-handoff-access-b";
    "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b"
  )
  # Access-client still has its default (unchanged)
  and has_default_via_ds(
    "esp0xdeadbeef-site-a-nixos-access-client";
    "p2p-nixos-access-client-nixos-downstream-selector";
    "10.10.44.1"
  )
' "${output_json}" >/dev/null
echo "PASS provider-handoff-downstream-default-route nixos substrate"

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

  def has_default_via_ds($target; $p2p_iface; $expected_via4):
    rt($target).effectiveRuntimeRealization.interfaces[$p2p_iface] as $iface
    | ($iface.routes.ipv4 // []) as $v4
    | ($v4 | map(select(.intent.kind == "default-reachability"))) as $defaults
    | ($defaults | length) == 1
    and $defaults[0].proto == "default"
    and $defaults[0].via4 == $expected_via4;

  def no_default($target; $iface_name):
    rt($target).effectiveRuntimeRealization.interfaces[$iface_name] as $iface
    | (($iface.routes.ipv4 // []) | map(select(.intent.kind == "default-reachability")) | length) == 0;

  # CLAB Provider A: default via downstream-selector
  has_default_via_ds(
    "esp0xdeadbeef-site-b-clab-provider-handoff-access-a";
    "p2p-clab-downstream-selector-clab-provider-handoff-access-a";
    "10.50.44.58"
  )
  # CLAB Provider A: NO default on PPPoE-linked p2p
  and no_default(
    "esp0xdeadbeef-site-b-clab-provider-handoff-access-a";
    "p2p-clab-core-testnet-host-isp-clab-provider-handoff-access-a"
  )
  # CLAB Provider B: default via downstream-selector
  and has_default_via_ds(
    "esp0xdeadbeef-site-b-clab-provider-handoff-access-b";
    "p2p-clab-downstream-selector-clab-provider-handoff-access-b";
    "10.50.44.60"
  )
  # CLAB Provider B: NO default on PPPoE-linked p2p
  and no_default(
    "esp0xdeadbeef-site-b-clab-provider-handoff-access-b";
    "p2p-clab-core-testnet-routed-isp-clab-provider-handoff-access-b"
  )
' "${output_json}" >/dev/null
echo "PASS provider-handoff-downstream-default-route clab substrate"

echo "PASS test-provider-handoff-downstream-default-route all substrates"
