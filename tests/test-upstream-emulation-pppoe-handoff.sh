#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

output_json="${tmp_dir}/cpm.json"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  /home/deadbeef/github/network-labs/sat/intent.nix \
  /home/deadbeef/github/network-labs/sat/inventory.nix \
  "${output_json}" >/dev/null

jq -e '
  def root: if type == "array" then .[0] else . end;
  root as $root
  | $root.control_plane_model.data.esp.nixos.upstreamEmulation.pppoeNixos as $nixos
  | $root.control_plane_model.data.esp.clab.upstreamEmulation.pppoeClab as $clab
  | def pppoe_ok($row; $backend; $bridge; $server; $core):
      $row.mode == "pppoe"
      and $row.backend == $backend
      and $row.handoff.bridge == $bridge
      and $row.handoff.mtu == 1492
      and $row.pppoe.server.implementation == "accel-ppp"
      and $row.pppoe.server.side == "provider"
      and $row.pppoe.server.node == $server
      and $row.pppoe.server.handoffBridge == $bridge
      and ($row.pppoe.server.credentials.usernameFile | startswith("/run/secrets/sat-pppoe-"))
      and ($row.pppoe.server.credentials.passwordFile | startswith("/run/secrets/sat-pppoe-"))
      and ($row.pppoe.server.session.ipv4Prefix | test("^203\\.0\\.113\\."))
      and ($row.pppoe.server.session.delegatedAggregate | test("^2001:db8:800:"))
      and $row.pppoe.client.coreNode == $core
      and $row.pppoe.client.coreInterface == "pppoe-wan"
      and $row.pppoe.client.runtimeInterface == "ppp0"
      and $row.pppoe.client.handoffBridge == $bridge
      and $row.pppoe.client.addressDelivery.ipv4 == "pppoe-session-address"
      and $row.pppoe.client.addressDelivery.ipv6 == "pppoe-delegated-prefix"
      and $row.pppoe.client.addressDelivery.wanDhcpFallback == false
      and $row.pppoe.client.addressDelivery.wanSlaacFallback == false
      and ($row.probeIntent | index("pppoe-session-up") != null)
      and ($row.probeIntent | index("no-wan-dhcp") != null)
      and ($row.probeIntent | index("no-wan-slaac") != null);
    pppoe_ok($nixos; "nixos"; "br-nix-pppoe"; "sat-nixos-pppoe-ac"; "nixos-router-core-isp-a")
    and pppoe_ok($clab; "clab"; "br-clab-pppoe"; "sat-clab-pppoe-ac"; "clab-router-core-simulated-isp")
' "${output_json}" >/dev/null

echo "PASS upstream-emulation-pppoe-handoff"
