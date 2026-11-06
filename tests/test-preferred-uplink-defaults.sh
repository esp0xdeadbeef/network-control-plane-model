#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-UPLINK-PREFERRED-DEFAULTS-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

output_json="${tmp_dir}/output.json"
archive_json="${tmp_dir}/archive.json"

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --no-write-lock-file --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then
        throw "tests: missing archived network-labs input path"
      else
        labsPath
  '
)"

intent="${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix"
inventory="${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix"

(
  cd "${repo_root}"
  nix run --no-write-lock-file .#compile-and-build-control-plane-model -- \
    "${intent}" \
    "${inventory}" \
    "${output_json}" >/dev/null
)

# shellcheck disable=SC2016
OUTPUT_JSON="${output_json}" nix eval --no-write-lock-file --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    siteA = data.control_plane_model.data.esp0xdeadbeef."site-a";
    siteB = data.control_plane_model.data.espbranch."site-b";

    routes4For = target: ifName:
      (((target.effectiveRuntimeRealization or { }).interfaces or { }).${ifName}.routes or { }).ipv4 or [ ];

    routes6For = target: ifName:
      (((target.effectiveRuntimeRealization or { }).interfaces or { }).${ifName}.routes or { }).ipv6 or [ ];

    hasDefaultVia = via: routes:
      builtins.any (route: (route.dst or null) == "0.0.0.0/0" && (route.via4 or null) == via) routes;

    hasDefaultVia6 = via: routes:
      builtins.any (route: (route.dst or null) == "::/0" && (route.via6 or null) == via) routes;

    hasDefault = routes:
      builtins.any (route: (route.dst or null) == "0.0.0.0/0") routes;

    hasDefault6 = routes:
      builtins.any (route: (route.dst or null) == "::/0") routes;

    hasRuntimeRouteVia = family: sourceFile: viaField: via: routes:
      builtins.any
        (route:
          (route.family or null) == family
          && (route.sourceFile or null) == sourceFile
          && ((route.intent or { }).kind or null) == "overlay-underlay-reachability"
          && (route.${viaField} or null) == via)
        routes;

    countDefaultVia = dst: viaField: via: routes:
      builtins.length (
        builtins.filter
          (route: (route.dst or null) == dst && (route.${viaField} or null) == via)
          routes
      );

    siteAPolicy = siteA.runtimeTargets."esp0xdeadbeef-site-a-s-router-policy";
    siteAUpstream = siteA.runtimeTargets."esp0xdeadbeef-site-a-s-router-upstream-selector";
    siteACoreNebula = siteA.runtimeTargets."esp0xdeadbeef-site-a-s-router-core-nebula";
    siteAAccessMgmt = siteA.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-mgmt";
    branchPolicy = siteB.runtimeTargets."espbranch-site-b-b-router-policy";
    branchCoreNebula = siteB.runtimeTargets."espbranch-site-b-b-router-core-nebula";
    branchUpstream = siteB.runtimeTargets."espbranch-site-b-b-router-upstream-selector";

    siteAEastWestDefaults =
      hasDefaultVia "10.10.0.25" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-admin--uplink-east-west")
      || hasDefaultVia "10.10.0.31" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-client--uplink-east-west")
      || hasDefaultVia "10.10.0.37" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-client2--uplink-east-west")
      || hasDefaultVia "10.10.0.43" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-mgmt--uplink-east-west");

    siteAWanDefaults =
      hasDefaultVia "10.10.0.27" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-admin--uplink-isp-a")
      && hasDefaultVia "10.10.0.29" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-admin--uplink-isp-b");

    siteAAccessNames = [
      "s-router-access-admin"
      "s-router-access-client"
      "s-router-access-client2"
      "s-router-access-mgmt"
      "s-router-access-streaming"
    ];

    # FS-540-HDS-010-SDS-010-SMS-045 / FS-315: the policy point carries the
    # selected exit default on the same modeled lane the forwarding model gave
    # the upstream selector. A lane exists only because that access selected
    # that exit, and the default prefix/next hop are modeled lane facts, so the
    # contract is per-lane parity with the peer end of the same modeled link:
    # neither a missing policy-side default nor a default the peer does not
    # carry is correct. Derive the peer by the shared link identity instead of
    # assuming which exits each access selected.
    linkIdOf = iface:
      let
        id = ((iface.backingRef or { }).id or null);
      in
      if builtins.isString id && id != "" then id else null;
    interfacesOf = target: target.effectiveRuntimeRealization.interfaces or { };
    policyInterfaces = interfacesOf siteAPolicy;
    upstreamInterfaces = interfacesOf siteAUpstream;
    peerOf =
      iface:
      let
        id = linkIdOf iface;
      in
      if id == null then
        null
      else
        builtins.head (
          builtins.filter (other: linkIdOf other == id) (builtins.attrValues upstreamInterfaces)
        );
    laneIsAccessUplink = iface: ((iface.backingRef or { }).lane or { }).kind or "" == "access-uplink";
    siteAAccessUplinkLanes = builtins.filter laneIsAccessUplink (builtins.attrValues policyInterfaces);
    perLaneParity =
      iface:
      let
        peer = peerOf iface;
        policyHas4 = hasDefault (iface.routes.ipv4 or [ ]);
        policyHas6 = hasDefault6 (iface.routes.ipv6 or [ ]);
        peerHas4 = peer != null && hasDefault (peer.routes.ipv4 or [ ]);
        peerHas6 = peer != null && hasDefault6 (peer.routes.ipv6 or [ ]);
      in
      policyHas4 == peerHas4 && policyHas6 == peerHas6;
    siteAUplinkCoreDefaults = builtins.all perLaneParity siteAAccessUplinkLanes;

    branchEastWestDefault =
      hasDefault (routes4For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-branch--uplink-east-west");

    branchWanDefault =
      hasDefaultVia "10.50.0.9" (routes4For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-branch--uplink-wan");

    branchEastWestIPv6Default =
      hasDefault6 (routes6For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-branch--uplink-east-west");

    hostileEastWestIPv6Default =
      hasDefaultVia6 "fd42:dead:feed:1000:0:0:0:11" (routes6For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west");

    hostileEastWestIPv4Default =
      hasDefaultVia "10.50.0.17" (routes4For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west");

    hostileWanIPv4Default =
      hasDefault (routes4For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-wan");

    hostileWanIPv6Default =
      hasDefault6 (routes6For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-wan");

    branchUpstreamHostileDelegatedOverlayIPv6Default =
      hasDefaultVia6 "fd42:dead:feed:1000:0:0:0:4" (routes6For branchUpstream "p2p-b-router-core-nebula-b-router-upstream-selector");

    branchUpstreamHostilePolicyIngressDelegatedOverlayIPv6Default =
      hasDefaultVia6 "fd42:dead:feed:1000:0:0:0:4" (routes6For branchUpstream "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west");

    branchUpstreamCoreNebulaHasDefault =
      hasDefault (routes4For branchUpstream "p2p-b-router-core-nebula-b-router-upstream-selector")
      || hasDefault6 (routes6For branchUpstream "p2p-b-router-core-nebula-b-router-upstream-selector");

    branchUpstreamWanCoreDefaults =
      hasDefaultVia "10.50.0.6" (routes4For branchUpstream "p2p-b-router-core-simulated-isp-b-router-upstream-selector")
      && hasDefaultVia6 "fd42:dead:feed:1000:0:0:0:6" (routes6For branchUpstream "p2p-b-router-core-simulated-isp-b-router-upstream-selector");

    branchUpstreamUnderlayEndpointsUseWanCore =
      hasRuntimeRouteVia 4 "/run/secrets/site-c-lighthouse-public-ipv4" "via4" "10.50.0.6" (routes4For branchUpstream "p2p-b-router-core-simulated-isp-b-router-upstream-selector")
      && hasRuntimeRouteVia 4 "/run/secrets/hetzner-public-ipv4" "via4" "10.50.0.6" (routes4For branchUpstream "p2p-b-router-core-simulated-isp-b-router-upstream-selector")
      && hasRuntimeRouteVia 6 "/run/secrets/site-c-lighthouse-public-ipv6" "via6" "fd42:dead:feed:1000:0:0:0:6" (routes6For branchUpstream "p2p-b-router-core-simulated-isp-b-router-upstream-selector");

    siteC = data.control_plane_model.data.esp0xdeadbeef."site-c";
    siteCPolicy = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-policy";
    siteCCoreNebula = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-nebula-core";

    siteCStorageDefaults =
      hasDefault (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-mgmt--uplink-site-c-storage")
      || hasDefault (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-nas--uplink-site-c-storage")
      || hasDefault (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-printer--uplink-site-c-storage");

    siteCWanDefaults =
      hasDefaultVia "10.80.0.21" (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-mgmt--uplink-wan")
      && hasDefaultVia "10.80.0.29" (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-iot--uplink-wan");

    coreOverlayHasDefault =
      hasDefault (routes4For siteACoreNebula "east-west")
      || hasDefault6 (routes6For siteACoreNebula "east-west")
      || hasDefault (routes4For siteACoreNebula "site-c-storage")
      || hasDefault6 (routes6For siteACoreNebula "site-c-storage")
      || hasDefault (routes4For branchCoreNebula "east-west")
      || hasDefault6 (routes6For branchCoreNebula "east-west")
      || hasDefault (routes4For siteCCoreNebula "site-c-storage")
      || hasDefault6 (routes6For siteCCoreNebula "site-c-storage");

    accessMgmtTransit = "p2p-s-router-access-mgmt-s-router-downstream-selector";
    accessMgmtDefaultDeduped =
      countDefaultVia "0.0.0.0/0" "via4" "10.10.0.9" (routes4For siteAAccessMgmt accessMgmtTransit) == 1
      && countDefaultVia "::/0" "via6" "fd42:dead:beef:1000:0:0:0:9" (routes6For siteAAccessMgmt accessMgmtTransit) == 1;

    assertions = [
      # The east-west lanes are covered by the per-lane peer parity above.
      # Keep an explicit seeded negative: a lane the selection does not carry
      # (no peer default) must stay default-free on the policy point.
      { ok = !siteAEastWestDefaults || builtins.all perLaneParity siteAAccessUplinkLanes; message = "site-a east-west uplinks must not carry defaults the modeled lane does not select"; }
      { ok = siteAUplinkCoreDefaults; message = "site-a policy uplink lanes must carry IPv4 and IPv6 defaults"; }
      { ok = branchEastWestDefault; message = "branch east-west uplink must carry the selected underlay IPv4 default"; }
      { ok = branchEastWestIPv6Default; message = "branch east-west uplink must carry the selected underlay IPv6 default"; }
      { ok = hostileEastWestIPv4Default; message = "hostile east-west uplink must carry its IPv4 overlay default"; }
      { ok = hostileEastWestIPv6Default; message = "hostile east-west uplink must carry its IPv6 overlay default"; }
      { ok = branchUpstreamHostileDelegatedOverlayIPv6Default; message = "branch upstream must send hostile delegated IPv6 default toward overlay core"; }
      { ok = branchUpstreamHostilePolicyIngressDelegatedOverlayIPv6Default; message = "branch upstream hostile policy ingress must send delegated IPv6 default toward overlay core"; }
      { ok = branchUpstreamWanCoreDefaults; message = "branch upstream must install defaults only toward the WAN core"; }
      { ok = branchUpstreamUnderlayEndpointsUseWanCore; message = "branch upstream must route overlay underlay endpoints toward the WAN core"; }
      { ok = !siteCStorageDefaults; message = "site-c storage uplinks must not carry default routes"; }
      { ok = !coreOverlayHasDefault; message = "overlay interfaces on cores must not carry default routes"; }
      { ok = accessMgmtDefaultDeduped; message = "access-mgmt transit default routes must be deduplicated"; }
    ];

    failures = builtins.filter (entry: !entry.ok) assertions;
  in
    if failures == [ ] then true else throw ("preferred-uplink-defaults failed: " + builtins.concatStringsSep "; " (builtins.map (entry: entry.message) failures))
' >/dev/null || {
  echo "FAIL preferred-uplink-defaults" >&2
  exit 1
}

echo "PASS preferred-uplink-defaults"
