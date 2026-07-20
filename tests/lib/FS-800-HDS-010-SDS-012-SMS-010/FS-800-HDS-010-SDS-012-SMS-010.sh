#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-012-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
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
    | select(
      .[-1] == "upstreamEmulation"
      or .[-1] == "providerAccess"
      or .[-1] == "failureExpectation"
      or .[-1] == "probeIntent"
    );
  def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
  def rt($target): site.runtimeTargets[$target];
  def has_site_attachment($unit; $name):
    any(site.attachments[]?; .kind == "tenant" and .unit == $unit and .name == $name);
  def has_target_attachment($target; $name):
    any(rt($target).attachments[]?; .kind == "tenant" and .name == $name);
  def has_policy_relation($id; $from; $uplink):
    any(site.communicationContract.allowedRelations[]?;
      .id == $id
      and .action == "allow"
      and .from == { "kind": "tenant", "name": $from }
      and .to == { "kind": "external", "uplinks": [ $uplink ] }
    );
  def has_traffic_path($id; $path):
    any(site.trafficPaths[]?; .relationId == $id and .nodePath == $path);
  def has_transit_lane($name; $kind; $access; $uplink):
    any(site.transit.adjacencies[]?;
      .name == $name
      and .laneMeta.kind == $kind
      and (.laneMeta.access // null) == $access
      and (.laneMeta.uplink // null) == $uplink
    );
  def has_wan_prefixes($target; $interface; $uplink; $v4Prefix; $v6Prefix; $v4Address; $v6Address):
    rt($target).effectiveRuntimeRealization.interfaces[$interface] as $iface
    | $iface.sourceKind == "wan"
      and $iface.upstream == $uplink
      and $iface.wan.ipv4 == [ $v4Prefix ]
      and $iface.wan.ipv6 == [ $v6Prefix ]
      and $iface.ipv4.address == $v4Address
      and $iface.ipv6.address == $v6Address
      and any($iface.routes.ipv4[]?;
        .dst == $v4Prefix
        and .proto == "upstream"
        and .intent.kind == "uplink-learned-reachability"
        and .intent.source == "explicit-uplink"
      )
      and any($iface.routes.ipv6[]?;
        .dst == $v6Prefix
        and .proto == "upstream"
        and .intent.kind == "uplink-learned-reachability"
        and .intent.source == "explicit-uplink"
      );
  def has_pppoe_client($target; $interface; $runtimeInterface):
    rt($target).services.pppoe.client as $client
    | $client.interface == $interface
      and $client.runtimeInterface == $runtimeInterface
      and $client.defaultRoute == true
      and $client.usePeerDns == true
      and $client.mtu == 1492;
  def has_pppoe_server($target; $interface; $providerAddress; $customerAddress):
    rt($target).services.pppoe.server as $server
    | $server.interface == $interface
      and $server.providerAddress == $providerAddress
      and $server.customerAddress == $customerAddress
      and $server.implementation == "rp-pppoe"
      and $server.mtu == 1492;
  def has_pppoe_session_interface($target; $runtimeInterface; $role; $address; $peer; $serviceInterface):
    rt($target).effectiveRuntimeRealization.interfaces[$runtimeInterface] as $iface
    | $iface.sourceKind == "pppoe-session"
      and $iface.runtimeIfName == $runtimeInterface
      and $iface.renderedIfName == $runtimeInterface
      and $iface.ipv4.address == ($address + "/32")
      and $iface.ipv4.peer == ($peer + "/32")
      and $iface.pppoe.role == $role
      and $iface.pppoe.serviceInterface == $serviceInterface
      and any($iface.routes.ipv4[]?;
        .dst == ($peer + "/32")
        and .proto == "pppoe-session"
        and .intent.kind == "connected-reachability"
      );
  def has_pppoe_client_session_interface($target; $runtimeInterface; $role; $address; $peer; $serviceInterface):
    has_pppoe_session_interface($target; $runtimeInterface; $role; $address; $peer; $serviceInterface)
    and any(rt($target).effectiveRuntimeRealization.interfaces[$runtimeInterface].routes.ipv4[]?;
      .dst == "0.0.0.0/0"
      and .proto == "pppoe-session"
      and .intent.kind == "default-reachability"
    );
  def has_forward_rule($target; $from; $to):
    any(rt($target).forwardingIntent.rules[]?;
      .action == "accept"
      and .fromInterface == $from
      and .toInterface == $to
    );
  def pppoe_targets:
    [
      site.runtimeTargets
      | to_entries[]
      | select(.value.services.pppoe? != null)
      | .key
    ] | sort;
  def provider_access_dhcp_slaac_disabled($target; $tenantIf):
    any(rt($target).advertisements.dhcp4[]?; .interface == $tenantIf and .enabled == false)
    and any(rt($target).advertisements.ipv6Ra[]?; .interface == $tenantIf and .enabled == false);
  def has_explicit_snat($target; $uplink; $interface):
    rt($target).natIntent as $nat
    | $nat.enabled == true
      and $nat.families == { "ipv4": true, "ipv6": false }
      and $nat.uplinks == [ $uplink ]
      and $nat.wanInterfaces == [ $interface ]
      and $nat.masqueradeInterfaces4 == [ $interface ]
      and $nat.masqueradeInterfaces6 == []
      and $nat.routeSafety.coreOriginUplinkDefault.mode == "blackholed"
      and $nat.routeSafety.coreOriginUplinkDefault.selectedUplinks == [ $uplink ]
      and $nat.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat44 == true
      and $nat.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 == false
      and $nat.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.snat == true
      and $nat.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.snatBoundaries == [ $uplink ];
  def no_access_translation_side_effect($target):
    rt($target).egressIntent.nat66 == {}
    and (rt($target).natIntent? == null);
  ([side_channel_path] == [])
    and site.siteId == "site-a"
    and site.upstreamSelectorNodeName == "nixos-upstream-selector"
    and (site.runtimeTargets | has("esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp"))
    and (site.runtimeTargets | has("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"))
    and (rt("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp").role == "core")
    and (rt("esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp").role == "core")
    and (rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a").role == "access")
    and (rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b").role == "access")
    and has_site_attachment("nixos-core-testnet-host-isp"; "provider-handoff-a")
    and has_site_attachment("nixos-core-testnet-routed-isp"; "provider-handoff-b")
    and has_site_attachment("nixos-provider-handoff-access-a"; "provider-handoff-a")
    and has_site_attachment("nixos-provider-handoff-access-b"; "provider-handoff-b")
    and has_target_attachment("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"; "provider-handoff-a")
    and has_target_attachment("esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp"; "provider-handoff-b")
    and has_policy_relation("allow-client-to-testnet-host-isp"; "client"; "testnet-host-isp")
    and has_policy_relation("allow-client-to-testnet-routed-isp"; "client"; "testnet-routed-isp")
    and has_policy_relation("allow-provider-handoff-a-to-isp-a"; "provider-handoff-a"; "isp-a")
    and has_policy_relation("allow-provider-handoff-b-to-isp-a"; "provider-handoff-b"; "isp-a")
    and has_traffic_path("allow-client-to-testnet-host-isp"; [
      "nixos-access-client",
      "nixos-downstream-selector",
      "nixos-policy",
      "nixos-upstream-selector",
      "nixos-core-testnet-host-isp"
    ])
    and has_traffic_path("allow-client-to-testnet-routed-isp"; [
      "nixos-access-client",
      "nixos-downstream-selector",
      "nixos-policy",
      "nixos-upstream-selector",
      "nixos-core-testnet-routed-isp"
    ])
    and has_traffic_path("allow-provider-handoff-a-to-isp-a"; [
      "nixos-provider-handoff-access-a",
      "nixos-downstream-selector",
      "nixos-policy",
      "nixos-upstream-selector",
      "nixos-core-upstream-vlan4"
    ])
    and has_traffic_path("allow-provider-handoff-b-to-isp-a"; [
      "nixos-provider-handoff-access-b",
      "nixos-downstream-selector",
      "nixos-policy",
      "nixos-upstream-selector",
      "nixos-core-upstream-vlan4"
    ])
    and has_transit_lane("p2p-nixos-downstream-selector-nixos-policy--access-nixos-provider-handoff-access-a"; "access"; "nixos-provider-handoff-access-a"; null)
    and has_transit_lane("p2p-nixos-downstream-selector-nixos-provider-handoff-access-a"; "access-edge"; "nixos-provider-handoff-access-a"; null)
    and has_transit_lane("p2p-nixos-policy-nixos-upstream-selector--access-nixos-provider-handoff-access-a--uplink-isp-a"; "access-uplink"; "nixos-provider-handoff-access-a"; "isp-a")
    and has_wan_prefixes(
      "esp0xdeadbeef-site-a-nixos-core-testnet-host-isp";
      "testnet-host-isp";
      "testnet-host-isp";
      "203.0.113.4/32";
      "2001:db8:113:64::/64";
      "203.0.113.5/32";
      "2001:db8:113:64::1/64"
    )
    and has_wan_prefixes(
      "esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp";
      "testnet-routed-isp";
      "testnet-routed-isp";
      "203.0.113.0/30";
      "2001:db8:113::/48";
      "203.0.113.1/30";
      "2001:db8:113::1/64"
    )
    and (rt("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp").egressIntent.uplinks == [ "testnet-host-isp" ])
    and (rt("esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp").egressIntent.uplinks == [ "testnet-routed-isp" ])
    and (rt("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp").routingAuthority.exitsSite == true)
    and (rt("esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp").routingAuthority.exitsSite == true)
    and (rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a").routingAuthority.exitsSite == false)
    and (rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b").routingAuthority.exitsSite == false)
    and has_pppoe_client("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"; "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a"; "ppp0")
    and has_pppoe_client("esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp"; "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b"; "ppp1")
    and has_pppoe_server("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a"; "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a"; "203.0.113.5"; "203.0.113.4")
    and has_pppoe_server("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b"; "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b"; "203.0.113.1"; "203.0.113.2")
    and has_pppoe_session_interface("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a"; "ppp0"; "server"; "203.0.113.5"; "203.0.113.4"; "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a")
    and has_pppoe_client_session_interface("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"; "ppp0"; "client"; "203.0.113.4"; "203.0.113.5"; "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a")
    and has_pppoe_session_interface("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b"; "ppp1"; "server"; "203.0.113.1"; "203.0.113.2"; "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b")
    and has_pppoe_client_session_interface("esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp"; "ppp1"; "client"; "203.0.113.2"; "203.0.113.1"; "p2p-nixos-core-testnet-routed-isp-nixos-provider-handoff-access-b")
    and has_forward_rule("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a"; "tenant-provider-handoff-a"; "ppp0")
    and has_forward_rule("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a"; "ppp0"; "tenant-provider-handoff-a")
    and has_forward_rule("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"; "ppp0"; "ens80")
    and has_forward_rule("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"; "ens80"; "ppp0")
    and pppoe_targets == [
      "esp0xdeadbeef-site-a-nixos-core-testnet-host-isp",
      "esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp",
      "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a",
      "esp0xdeadbeef-site-a-nixos-provider-handoff-access-b"
    ]
    and provider_access_dhcp_slaac_disabled("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a"; "tenant-provider-handoff-a")
    and provider_access_dhcp_slaac_disabled("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b"; "tenant-provider-handoff-b")
    and has_explicit_snat("esp0xdeadbeef-site-a-nixos-core-testnet-host-isp"; "testnet-host-isp"; "ens80")
    and has_explicit_snat("esp0xdeadbeef-site-a-nixos-core-testnet-routed-isp"; "testnet-routed-isp"; "ens80")
    and no_access_translation_side_effect("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a")
    and no_access_translation_side_effect("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b")
    and (rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a").effectiveRuntimeRealization.interfaces.ppp0.routes.ipv4
      | map(select(.intent.kind == "default-reachability")) == [])
    and (rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b").effectiveRuntimeRealization.interfaces.ppp1.routes.ipv4
      | map(select(.intent.kind == "default-reachability")) == [])
' "${output_json}" >/dev/null

echo "PASS provider-access-no-side-channel row-semantics"
