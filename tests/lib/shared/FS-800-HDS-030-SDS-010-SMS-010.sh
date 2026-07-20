#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-030-SDS-010-SMS-010
# GAMP-ID: FS-800-HDS-030-SDS-020-SMS-010
# GAMP-SCOPE: CPM construction test; no HAT/SAT runtime claim
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

network_labs="$(pinned_network_labs)"
hat_dir="${network_labs}/GAMP/HAT/emulated-isp-residential-testnet"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run --no-warn-dirty --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    --override-input network-labs "path:${network_labs}" \
    "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${hat_dir}/intent.nix" \
    "${hat_dir}/${inventory}" \
    "${output}" >/dev/null
}

nixos_json="${tmp_dir}/cpm-nixos.json"
clab_json="${tmp_dir}/cpm-clab.json"
build_cpm "inventory-nixos.nix" "${nixos_json}"
build_cpm "inventory-clab.nix" "${clab_json}"

jq -e '
  def root: if type == "array" then .[0] else . end;
  def site($site): root.control_plane_model.data.esp0xdeadbeef[$site];
  def rt($site; $target): site($site).runtimeTargets[$target];
  def has_handoff($site; $target; $iface; $role; $bridge):
    rt($site; $target).effectiveRuntimeRealization.interfaces[$iface] as $lower
    | rt($site; $target).services.pppoe[$role].interface == $iface
      and $lower.sourceKind == "pppoe-handoff"
      and $lower.runtimeIfName == "ens20"
      and $lower.renderedIfName == "ens20"
      and $lower.addr4 == null
      and $lower.addr6 == null
      and $lower.routes == { "ipv4": [], "ipv6": [] }
      and $lower.attach.kind == "bridge"
      and $lower.attach.bridge == $bridge
      and $lower.backingRef.kind == "service-interface"
      and $lower.backingRef.service == "pppoe"
      and $lower.backingRef.serviceRole == $role
      and $lower.backingRef.name == $iface
      and $lower.pppoe.role == $role
      and $lower.pppoe.serviceInterface == $iface;

  has_handoff(
    "site-a";
    "esp0xdeadbeef-site-a-nixos-core-testnet-host-isp";
    "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a";
    "client";
    "br-site-a-p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a"
  )
  and has_handoff(
    "site-a";
    "esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp";
    "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b";
    "client";
    "br-site-a-p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b"
  )
  and has_handoff(
    "site-a";
    "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a";
    "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a";
    "server";
    "br-site-a-p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a"
  )
  and has_handoff(
    "site-a";
    "esp0xdeadbeef-site-a-nixos-provider-handoff-access-b";
    "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b";
    "server";
    "br-site-a-p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b"
  )
' "${nixos_json}" >/dev/null

jq -e '
  def root: if type == "array" then .[0] else . end;
  def site($site): root.control_plane_model.data.esp0xdeadbeef[$site];
  def rt($site; $target): site($site).runtimeTargets[$target];
  def has_handoff($site; $target; $iface; $role; $bridge):
    rt($site; $target).effectiveRuntimeRealization.interfaces[$iface] as $lower
    | rt($site; $target).services.pppoe[$role].interface == $iface
      and $lower.sourceKind == "pppoe-handoff"
      and $lower.runtimeIfName == "ens20"
      and $lower.renderedIfName == "ens20"
      and $lower.addr4 == null
      and $lower.addr6 == null
      and $lower.routes == { "ipv4": [], "ipv6": [] }
      and $lower.attach.kind == "bridge"
      and $lower.attach.bridge == $bridge
      and $lower.backingRef.kind == "service-interface"
      and $lower.backingRef.service == "pppoe"
      and $lower.backingRef.serviceRole == $role
      and $lower.backingRef.name == $iface
      and $lower.pppoe.role == $role
      and $lower.pppoe.serviceInterface == $iface;

  has_handoff(
    "site-b";
    "esp0xdeadbeef-site-b-clab-core-testnet-host-isp";
    "p2p-clab-core-testnet-host-isp-clab-provider-handoff-access-a";
    "client";
    "br-site-b-p2p-clab-core-testnet-host-isp-clab-provider-handoff-access-a"
  )
  and has_handoff(
    "site-b";
    "esp0xdeadbeef-site-b-clab-core-testnet-routed-isp";
    "p2p-clab-core-testnet-routed-isp-clab-provider-handoff-access-b";
    "client";
    "br-site-b-p2p-clab-core-testnet-routed-isp-clab-provider-handoff-access-b"
  )
  and has_handoff(
    "site-b";
    "esp0xdeadbeef-site-b-clab-provider-handoff-access-a";
    "p2p-clab-core-testnet-host-isp-clab-provider-handoff-access-a";
    "server";
    "br-site-b-p2p-clab-core-testnet-host-isp-clab-provider-handoff-access-a"
  )
  and has_handoff(
    "site-b";
    "esp0xdeadbeef-site-b-clab-provider-handoff-access-b";
    "p2p-clab-core-testnet-routed-isp-clab-provider-handoff-access-b";
    "server";
    "br-site-b-p2p-clab-core-testnet-routed-isp-clab-provider-handoff-access-b"
  )
' "${clab_json}" >/dev/null

echo "PASS FS-800-HDS-030-SDS-010/020 PPPoE service-interface CPM contract"
