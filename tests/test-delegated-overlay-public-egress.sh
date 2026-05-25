#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

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
    branchPolicy = siteB.runtimeTargets."espbranch-site-b-b-router-policy";
    siteCUpstream = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector";
    siteCCore = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-core";
    siteCCoreNebula = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-nebula-core";
    interfaces = coreNebula.effectiveRuntimeRealization.interfaces;
    upstreamInterfaces = upstreamSelector.effectiveRuntimeRealization.interfaces;
    policyInterfaces = branchPolicy.effectiveRuntimeRealization.interfaces;
    siteCUpstreamInterfaces = siteCUpstream.effectiveRuntimeRealization.interfaces;
    siteCCoreInterfaces = siteCCore.effectiveRuntimeRealization.interfaces;
    siteCCoreNebulaInterfaces = siteCCoreNebula.effectiveRuntimeRealization.interfaces;

    routes6For = ifName:
      (((interfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    routes4For = ifName:
      (((interfaces.${ifName} or { }).routes or { }).ipv4 or [ ]);
    upstreamRoutes6For = ifName:
      (((upstreamInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    siteCUpstreamRoutes6For = ifName:
      (((siteCUpstreamInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    siteCUpstreamRoutes4For = ifName:
      (((siteCUpstreamInterfaces.${ifName} or { }).routes or { }).ipv4 or [ ]);
    siteCCoreRoutes6For = ifName:
      (((siteCCoreInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    siteCCoreRoutes4For = ifName:
      (((siteCCoreInterfaces.${ifName} or { }).routes or { }).ipv4 or [ ]);
    siteCCoreNebulaRoutes6For = ifName:
      (((siteCCoreNebulaInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    siteCCoreNebulaRoutes4For = ifName:
      (((siteCCoreNebulaInterfaces.${ifName} or { }).routes or { }).ipv4 or [ ]);
    policyRoutes6For = ifName:
      (((policyInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);

    delegatedOverlayDefault =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.scope or null) == "link"
          && (route.policyOnly or false) == true
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "b-router-access-hostile")
        (routes6For "overlay-east-west");

    delegatedOverlayDefault4 =
      builtins.any
        (route:
          (route.dst or null) == "0.0.0.0/0"
          && (route.scope or null) == "link"
          && (route.policyOnly or false) == true
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "b-router-access-hostile")
        (routes4For "overlay-east-west");

    underlayDefaultPreserved =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.via6 or null) == "fd42:dead:feed:1000:0:0:0:5"
          && ((route.intent or { }).kind or null) == "default-reachability")
        (routes6For "p2p-b-router-core-nebula-b-router-upstream-selector");

    upstreamHostileDefaultToOverlay =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.via6 or null) == "fd42:dead:feed:1000:0:0:0:4"
          && (route.policyOnly or false) == true
          && ((route.lane or { }).access or null) == "b-router-access-hostile"
          && ((route.intent or { }).kind or null) == "default-reachability")
        (upstreamRoutes6For "p2p-b-router-core-nebula-b-router-upstream-selector");

    hostilePolicyIngressDelegatedDefaultToOverlay =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.via6 or null) == "fd42:dead:feed:1000:0:0:0:4"
          && (route.policyOnly or false) == true
          && ((route.intent or { }).kind or null) == "default-reachability")
        (upstreamRoutes6For "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west");

    hostileRuntimeReturnOnHostileIngress =
      builtins.any
        (route:
          (route.sourceFile or null) == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
          && (route.via6 or null) == "fd42:dead:feed:1000:0:0:0:a"
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return"
          && ((route.intent or { }).accessNode or null) == "b-router-access-hostile")
        (policyRoutes6For "p2p-b-router-downstream-selector-b-router-policy--access-b-router-access-hostile");

    hostileRuntimeReturnNotOnBranchIngress =
      !(builtins.any
        (route:
          (route.sourceFile or null) == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (policyRoutes6For "p2p-b-router-downstream-selector-b-router-policy--access-b-router-access-branch"));

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
          && ((route.intent or { }).kind or null) == "default-reachability")
        (siteCUpstreamRoutes6For "p2p-c-router-nebula-core-c-router-upstream-selector");

    siteCUpstreamReturnsHostilePrefixToCoreNebula =
      builtins.any
        (route:
          (route.sourceFile or null) == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
          && (route.via6 or null) == "fd42:dead:cafe:1000:0:0:0:a"
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (siteCUpstreamRoutes6For "p2p-c-router-nebula-core-c-router-upstream-selector");

    siteCUpstreamReturnsHostileTenantV4ToCoreNebula =
      builtins.any
        (route:
          (route.dst or null) == "10.70.10.0/24"
          && (route.via4 or null) == "10.80.0.10"
          && ((route.intent or { }).kind or null) == "overlay-reachability")
        (siteCUpstreamRoutes4For "p2p-c-router-nebula-core-c-router-upstream-selector");

    siteCUpstreamDoesNotReturnHostilePrefixToClientPolicy =
      !(builtins.any
        (route:
          (route.sourceFile or null) == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (siteCUpstreamRoutes6For "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-client--uplink-east-west"));

    siteCCoreNebulaDoesNotCarrySiteCClientOverlayDefault =
      !(builtins.any
        (route:
          (route.dst or null) == "::/0"
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "c-router-access-client")
        (siteCCoreNebulaRoutes6For "overlay-east-west"));

    siteCCoreNebulaReturnsHostilePrefixOverOverlay =
      builtins.any
        (route:
          (route.sourceFile or null) == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
          && (route.proto or null) == "overlay"
          && !(route ? via6)
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (siteCCoreNebulaRoutes6For "overlay-east-west");

    siteCCoreNebulaReturnsHostileTenantV4OverOverlay =
      builtins.any
        (route:
          (route.dst or null) == "10.70.10.0/24"
          && (route.proto or null) == "overlay"
          && !(route ? via4)
          && ((route.intent or { }).kind or null) == "overlay-reachability")
        (siteCCoreNebulaRoutes4For "overlay-east-west");

    siteCCoreNebulaDoesNotReturnHostilePrefixToUpstream =
      !(builtins.any
        (route:
          (route.sourceFile or null) == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (siteCCoreNebulaRoutes6For "p2p-c-router-nebula-core-c-router-upstream-selector"));

    siteCCoreReturnsHostilePrefixToUpstream =
      builtins.any
        (route:
          (route.sourceFile or null) == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
          && (route.via6 or null) == "fd42:dead:cafe:1000:0:0:0:5"
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (siteCCoreRoutes6For "p2p-c-router-core-c-router-upstream-selector");

    siteCCoreReturnsHostileTenantV4ToUpstream =
      builtins.any
        (route:
          (route.dst or null) == "10.70.10.0/24"
          && (route.via4 or null) == "10.80.0.5"
          && ((route.intent or { }).kind or null) == "overlay-reachability")
        (siteCCoreRoutes4For "p2p-c-router-core-c-router-upstream-selector");

    siteCOverlayIngressFirewallToPolicy =
      builtins.any
        (rule:
          (rule.fromInterface or null) == "core-nebula"
          && (rule.toInterface or null) == "pol-client-ew"
          && (rule.action or null) == "accept")
        (siteCUpstream.forwardingIntent.rules or [ ]);

    siteCOverlayIngressFirewallScopedToHostilePrefix =
      builtins.any
        (rule:
          (rule.fromInterface or null) == "core-nebula"
          && (rule.toInterface or null) == "pol-client-ew"
          && (rule.action or null) == "accept"
          && builtins.elem "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile" (rule.sourceFiles or [ ])
          && ((rule.intent or { }).kind or null) == "runtime-routed-prefix-public-egress")
        (siteCUpstream.forwardingIntent.rules or [ ]);

    siteCOverlayIngressFirewallScopedToHostileTenantV4 =
      builtins.any
        (rule:
          (rule.fromInterface or null) == "core-nebula"
          && (rule.toInterface or null) == "pol-client-ew"
          && (rule.action or null) == "accept"
          && builtins.any (prefix: (prefix.prefix or null) == "10.70.10.0/24") (rule.sourcePrefixes or [ ])
          && ((rule.intent or { }).kind or null) == "runtime-routed-prefix-public-egress")
        (siteCUpstream.forwardingIntent.rules or [ ]);

    siteCOverlayIngressFirewallNotScopedToDmz =
      !builtins.any
        (rule:
          (rule.fromInterface or null) == "core-nebula"
          && (rule.toInterface or null) == "pol-dmz-ew"
          && builtins.elem "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile" (rule.sourceFiles or [ ])
          && ((rule.intent or { }).kind or null) == "runtime-routed-prefix-public-egress")
        (siteCUpstream.forwardingIntent.rules or [ ]);
  in
    if delegatedOverlayDefault && delegatedOverlayDefault4 && upstreamHostileDefaultToOverlay && hostilePolicyIngressDelegatedDefaultToOverlay && hostileRuntimeReturnOnHostileIngress && hostileRuntimeReturnNotOnBranchIngress && underlayDefaultPreserved && !badGenericOverlayDefault && siteCOverlayIngressDefaultToPolicy && siteCUpstreamReturnsHostilePrefixToCoreNebula && siteCUpstreamReturnsHostileTenantV4ToCoreNebula && siteCUpstreamDoesNotReturnHostilePrefixToClientPolicy && siteCCoreNebulaDoesNotCarrySiteCClientOverlayDefault && siteCCoreNebulaReturnsHostilePrefixOverOverlay && siteCCoreNebulaReturnsHostileTenantV4OverOverlay && siteCCoreNebulaDoesNotReturnHostilePrefixToUpstream && siteCCoreReturnsHostilePrefixToUpstream && siteCCoreReturnsHostileTenantV4ToUpstream && siteCOverlayIngressFirewallToPolicy && siteCOverlayIngressFirewallScopedToHostilePrefix && siteCOverlayIngressFirewallScopedToHostileTenantV4 && siteCOverlayIngressFirewallNotScopedToDmz then
      true
    else if !siteCUpstreamReturnsHostileTenantV4ToCoreNebula || !siteCCoreNebulaReturnsHostileTenantV4OverOverlay || !siteCCoreReturnsHostileTenantV4ToUpstream then
      throw "delegated-overlay-public-egress failed: site-c must return branch hostile tenant IPv4 10.70.10.0/24 through core-nebula and overlay-east-west. Live symptom: hostile IPv4 public egress replies reached the overlay exit, then died until 10.20.70.0/24 return routes were hotpatched on Hetzner upstream/downstream/Nebula-core and local core-nebula."
    else if !siteCOverlayIngressFirewallScopedToHostileTenantV4 then
      throw "delegated-overlay-public-egress failed: site-c upstream selector must source-scope IPv4 hostile tenant public egress from core-nebula to pol-client-ew, not rely on an unscoped overlay cross-connect."
    else if !delegatedOverlayDefault4 then
      throw "delegated-overlay-public-egress failed: b-router-core-nebula overlay-east-west must carry a policyOnly delegated-public-egress 0.0.0.0/0 for hostile IPv4 exit. Live symptom: b-router-core-nebula needed manual 0.0.0.0/1 and 128.0.0.0/1 Nebula routes after restart."
    else if !siteCUpstreamReturnsHostilePrefixToCoreNebula || !siteCUpstreamDoesNotReturnHostilePrefixToClientPolicy then
      throw "delegated-overlay-public-egress failed: site-c upstream selector must return the branch hostile delegated prefix toward core-nebula, not a local client policy lane. Live symptom: c-router-upstream-selector returned echo replies toward pol-client-ew until a route to core-nebula was hotpatched."
    else if !siteCCoreNebulaReturnsHostilePrefixOverOverlay || !siteCCoreNebulaDoesNotReturnHostilePrefixToUpstream then
      throw "delegated-overlay-public-egress failed: site-c Nebula core must return the remote hostile delegated prefix over overlay-east-west, not back to the upstream selector. Live symptom: echo replies looped on c-router-nebula-core upstream until TTL expired."
    else if !siteCCoreReturnsHostilePrefixToUpstream then
      throw "delegated-overlay-public-egress failed: site-c WAN core must return the remote hostile delegated prefix toward c-router-upstream-selector. Live symptom: Hetzner WAN replies entered c-router-core, then routed the delegated prefix back to eth0/host gateway instead of the modeled policy return path."
    else if !siteCOverlayIngressFirewallScopedToHostilePrefix then
      throw "delegated-overlay-public-egress failed: example hostile IPv6 public egress requires a sourceFile-scoped core-nebula -> pol-client-ew firewall contract on site-c upstream-selector, not a broad core cross-connect."
    else if !siteCOverlayIngressFirewallNotScopedToDmz then
      throw "delegated-overlay-public-egress failed: example hostile IPv6 public egress must not fan out sourceFile-scoped egress permission from core-nebula to unrelated policy lanes such as pol-dmz-ew."
    else if !siteCOverlayIngressFirewallToPolicy then
      throw "delegated-overlay-public-egress failed: example site-c upstream-selector lacks forwarding intent from core-nebula to pol-client-ew for runtime delegated public egress."
    else if !siteCOverlayIngressDefaultToPolicy then
      throw "delegated-overlay-public-egress failed: example hostile IPv6 public egress would bypass policy at c-router-upstream-selector core-nebula ingress. CPM must emit a policyOnly default toward the policy east-west lane, not a delegated-public-egress default directly toward core."
    else if !siteCCoreNebulaDoesNotCarrySiteCClientOverlayDefault then
      throw "delegated-overlay-public-egress failed: example site-c Nebula core must not carry a delegated-public-egress ::/0 for c-router-access-client on overlay-east-west. Live symptom: hostile public IPv6 looped between fd42:dead:beef:ee::3 and fd42:dead:beef:ee::2 because site-c installed a public default back into Nebula."
    else if !hostileRuntimeReturnOnHostileIngress || !hostileRuntimeReturnNotOnBranchIngress then
      throw "delegated-overlay-public-egress failed: hostile runtime routed-prefix return route must be installed on b-router-policy downstr-hostile via fd42:dead:feed:1000:0:0:0:a, not on downstr-branch. Live symptom: hostile public IPv6 packets reached b-router-policy and died because the kernel selected the wrong ingress table."
    else if !upstreamHostileDefaultToOverlay then
      throw "delegated-overlay-public-egress failed: b-router-upstream-selector core-nebula ingress must keep a hostile policyOnly default-reachability route toward b-router-core-nebula for b-router-access-hostile public egress."
    else
      throw "delegated-overlay-public-egress failed: expected b-router-core-nebula overlay-east-west to carry a policyOnly delegated-public-egress ::/0, b-router-upstream-selector core-nebula to preserve its hostile policy default toward overlay, and b-router-upstream-selector pol-hostile-ew to route hostile delegated IPv6 default toward core-nebula for b-router-access-hostile. Remove this error only after CPM emits that ingress-lane renderer contract and live ip -6 route get from pol-hostile-ew selects core-nebula without moving underlay endpoint routes off WAN."
' >/dev/null

echo "PASS delegated-overlay-public-egress"
