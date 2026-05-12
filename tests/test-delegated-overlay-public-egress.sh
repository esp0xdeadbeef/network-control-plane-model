#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "delegated-overlay-public-egress: missing network-labs input" else labsPath
  '
)"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
    "${output_json}" >/dev/null
)

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    siteB = data.control_plane_model.data.espbranch."site-b";
    siteC = data.control_plane_model.data.esp0xdeadbeef."site-c";
    coreNebula = siteB.runtimeTargets."espbranch-site-b-b-router-core-nebula";
    upstreamSelector = siteB.runtimeTargets."espbranch-site-b-b-router-upstream-selector";
    siteCUpstream = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector";
    interfaces = coreNebula.effectiveRuntimeRealization.interfaces;
    upstreamInterfaces = upstreamSelector.effectiveRuntimeRealization.interfaces;
    siteCUpstreamInterfaces = siteCUpstream.effectiveRuntimeRealization.interfaces;

    routes6For = ifName:
      (((interfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    upstreamRoutes6For = ifName:
      (((upstreamInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    siteCUpstreamRoutes6For = ifName:
      (((siteCUpstreamInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);

    delegatedOverlayDefault =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.scope or null) == "link"
          && (route.policyOnly or false) == true
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "b-router-access-hostile")
        (routes6For "overlay-east-west");

    underlayDefaultPreserved =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.via6 or null) == "fd42:dead:feed:1000:0:0:0:5"
          && ((route.intent or { }).kind or null) == "default-reachability")
        (routes6For "p2p-b-router-core-nebula-b-router-upstream-selector");

    upstreamDelegatedDefaultToOverlay =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.via6 or null) == "fd42:dead:feed:1000:0:0:0:4"
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "b-router-access-hostile")
        (upstreamRoutes6For "p2p-b-router-core-nebula-b-router-upstream-selector");

    hostilePolicyIngressDelegatedDefaultToOverlay =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.via6 or null) == "fd42:dead:feed:1000:0:0:0:4"
          && (route.policyOnly or false) == true
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "b-router-access-hostile")
        (upstreamRoutes6For "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west");

    badGenericOverlayDefault =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && !(
            (route.policyOnly or false) == true
            && ((route.intent or { }).kind or null) == "delegated-public-egress"
          ))
        (routes6For "overlay-east-west");

    siteCOverlayIngressDefaultToPolicy =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.via6 or null) == "fd42:dead:cafe:1000:0:0:0:c"
          && (route.policyOnly or false) == true
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "c-router-access-client")
        (siteCUpstreamRoutes6For "p2p-c-router-nebula-core-c-router-upstream-selector");

    siteCClientEwCarriesOnlyPolicyDefault =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.policyOnly or false) == true
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "c-router-access-client")
        (siteCUpstreamRoutes6For "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-client--uplink-east-west");

    siteCOverlayIngressFirewallToPolicy =
      builtins.any
        (rule:
          (rule.fromInterface or null) == "core-nebula"
          && (rule.toInterface or null) == "pol-client-ew"
          && (rule.action or null) == "accept")
        (siteCUpstream.forwardingIntent.rules or [ ]);
  in
    if delegatedOverlayDefault && upstreamDelegatedDefaultToOverlay && hostilePolicyIngressDelegatedDefaultToOverlay && underlayDefaultPreserved && !badGenericOverlayDefault && siteCOverlayIngressDefaultToPolicy && siteCClientEwCarriesOnlyPolicyDefault && siteCOverlayIngressFirewallToPolicy then
      true
    else if !siteCOverlayIngressFirewallToPolicy then
      throw "delegated-overlay-public-egress failed: example site-c upstream-selector lacks forwarding intent from core-nebula to pol-client-ew, so the route contract would bypass the client tenant policy lane that owns the runtime delegated public prefix. Remove this error only after CPM emits the site-c overlay-ingress firewall contract."
    else if !siteCOverlayIngressDefaultToPolicy then
      throw "delegated-overlay-public-egress failed: example hostile IPv6 public egress would die at c-router-upstream-selector core-nebula ingress. CPM must emit a policyOnly delegated-public-egress ::/0 on site-c c-router-upstream-selector core-nebula via fd42:dead:cafe:1000:0:0:0:c toward pol-client-ew with exitNode=c-router-access-client."
    else if !siteCClientEwCarriesOnlyPolicyDefault then
      throw "delegated-overlay-public-egress failed: example site-c client east-west policy lane must carry only a policyOnly delegated public default while overlay ingress owns the concrete handoff toward the policy peer."
    else
      throw "delegated-overlay-public-egress failed: expected b-router-core-nebula overlay-east-west to carry a policyOnly delegated-public-egress ::/0, b-router-upstream-selector core-nebula to preserve its overlay default, and b-router-upstream-selector pol-hostile-ew to route hostile delegated IPv6 default toward core-nebula for b-router-access-hostile. Remove this error only after CPM emits that ingress-lane renderer contract and live ip -6 route get from pol-hostile-ew selects core-nebula without moving underlay endpoint routes off WAN."
' >/dev/null

echo "PASS delegated-overlay-public-egress"
