#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="/home/deadbeef/github/network-labs/HAT/emulated-isp-residential-testnet"
output_json="${tmp_dir}/cpm.json"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${hat_dir}/intent.nix" \
  "${hat_dir}/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -e '
  def root: if type == "array" then .[0] else . end;
  def side_channel_path:
    root.control_plane_model
    | paths
    | select(.[-1] == "upstreamEmulation" or .[-1] == "providerAccess");
  def has_pppoe_client($target; $interface; $runtimeInterface):
    $target.services.pppoe.client.interface == $interface
    and $target.services.pppoe.client.runtimeInterface == $runtimeInterface
    and $target.services.pppoe.client.defaultRoute == true;
  def has_pppoe_server($target; $interface; $providerAddress; $customerAddress):
    $target.services.pppoe.server.interface == $interface
    and $target.services.pppoe.server.providerAddress == $providerAddress
    and $target.services.pppoe.server.customerAddress == $customerAddress;
  root.control_plane_model.data.esp0xdeadbeef."site-a" as $site
  | ([side_channel_path] == [])
    and ($site.runtimeTargets | has("esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp"))
    and ($site.runtimeTargets | has("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"))
    and ([
      $site.trafficPaths[]
      | select(.relationId == "allow-client-to-testnet-host-isp")
      | .nodePath
    ] == [[
      "nixos-access-client",
      "nixos-downstream-selector",
      "nixos-policy",
      "nixos-upstream-selector",
      "nixos-core-testnet-host-isp"
    ]])
    and has_pppoe_client($site.runtimeTargets."esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"; "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a"; "ppp0")
    and has_pppoe_client($site.runtimeTargets."esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp"; "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b"; "ppp1")
    and has_pppoe_server($site.runtimeTargets."esp0xdeadbeef-site-a-nixos-provider-handoff-access-a"; "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a"; "203.0.113.5"; "203.0.113.4")
    and has_pppoe_server($site.runtimeTargets."esp0xdeadbeef-site-a-nixos-provider-handoff-access-b"; "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b"; "203.0.113.1"; "203.0.113.2")
' "${output_json}" >/dev/null

echo "PASS provider-access-no-side-channel"
