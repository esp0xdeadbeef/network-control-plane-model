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
    branchPolicy = siteB.runtimeTargets."espbranch-site-b-b-router-policy";
    siteCUpstream = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector";
    siteCCoreNebula = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-nebula-core";
    interfaces = coreNebula.effectiveRuntimeRealization.interfaces;
    upstreamInterfaces = upstreamSelector.effectiveRuntimeRealization.interfaces;
    policyInterfaces = branchPolicy.effectiveRuntimeRealization.interfaces;
    siteCUpstreamInterfaces = siteCUpstream.effectiveRuntimeRealization.interfaces;
    siteCCoreNebulaInterfaces = siteCCoreNebula.effectiveRuntimeRealization.interfaces;

    routes6For = ifName:
      (((interfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    upstreamRoutes6For = ifName:
      (((upstreamInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    siteCUpstreamRoutes6For = ifName:
      (((siteCUpstreamInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    siteCCoreNebulaRoutes6For = ifName:
      (((siteCCoreNebulaInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
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

    siteCOverlayIngressDefaultToCore =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.via6 or null) == "fd42:dead:cafe:1000:0:0:0:4"
          && (route.policyOnly or false) == true
          && ((route.intent or { }).kind or null) == "delegated-public-egress")
        (siteCUpstreamRoutes6For "p2p-c-router-nebula-core-c-router-upstream-selector");

    siteCUpstreamReturnsHostilePrefixToCoreNebula =
      builtins.any
        (route:
          (route.sourceFile or null) == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
          && (route.via6 or null) == "fd42:dead:cafe:1000:0:0:0:a"
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (siteCUpstreamRoutes6For "p2p-c-router-nebula-core-c-router-upstream-selector");

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

    siteCCoreNebulaDoesNotReturnHostilePrefixToUpstream =
      !(builtins.any
        (route:
          (route.sourceFile or null) == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (siteCCoreNebulaRoutes6For "p2p-c-router-nebula-core-c-router-upstream-selector"));

    siteCOverlayIngressFirewallToCore =
      builtins.any
        (rule:
          (rule.fromInterface or null) == "core-nebula"
          && (rule.toInterface or null) == "core"
          && (rule.action or null) == "accept")
        (siteCUpstream.forwardingIntent.rules or [ ]);

    siteCOverlayIngressFirewallScopedToHostilePrefix =
      builtins.any
        (rule:
          (rule.fromInterface or null) == "core-nebula"
          && (rule.toInterface or null) == "core"
          && (rule.action or null) == "accept"
          && builtins.elem "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile" (rule.sourceFiles or [ ])
          && ((rule.intent or { }).kind or null) == "runtime-routed-prefix-public-egress")
        (siteCUpstream.forwardingIntent.rules or [ ]);
  in
    if delegatedOverlayDefault && upstreamDelegatedDefaultToOverlay && hostilePolicyIngressDelegatedDefaultToOverlay && hostileRuntimeReturnOnHostileIngress && hostileRuntimeReturnNotOnBranchIngress && underlayDefaultPreserved && !badGenericOverlayDefault && siteCOverlayIngressDefaultToCore && siteCUpstreamReturnsHostilePrefixToCoreNebula && siteCUpstreamDoesNotReturnHostilePrefixToClientPolicy && siteCCoreNebulaDoesNotCarrySiteCClientOverlayDefault && siteCCoreNebulaReturnsHostilePrefixOverOverlay && siteCCoreNebulaDoesNotReturnHostilePrefixToUpstream && siteCOverlayIngressFirewallToCore && siteCOverlayIngressFirewallScopedToHostilePrefix then
      true
    else if !siteCUpstreamReturnsHostilePrefixToCoreNebula || !siteCUpstreamDoesNotReturnHostilePrefixToClientPolicy then
      throw "delegated-overlay-public-egress failed: site-c upstream selector must return the branch hostile delegated prefix toward core-nebula, not a local client policy lane. Live symptom: c-router-upstream-selector returned echo replies toward pol-client-ew until a route to core-nebula was hotpatched."
    else if !siteCCoreNebulaReturnsHostilePrefixOverOverlay || !siteCCoreNebulaDoesNotReturnHostilePrefixToUpstream then
      throw "delegated-overlay-public-egress failed: site-c Nebula core must return the remote hostile delegated prefix over overlay-east-west, not back to the upstream selector. Live symptom: echo replies looped on c-router-nebula-core upstream until TTL expired."
    else if !siteCOverlayIngressFirewallScopedToHostilePrefix then
      throw "delegated-overlay-public-egress failed: example hostile IPv6 public egress requires a sourceFile-scoped core-nebula -> core firewall contract on site-c upstream-selector, not a broad core cross-connect."
    else if !siteCOverlayIngressFirewallToCore then
      throw "delegated-overlay-public-egress failed: example site-c upstream-selector lacks forwarding intent from core-nebula to core for runtime delegated public egress."
    else if !siteCOverlayIngressDefaultToCore then
      throw "delegated-overlay-public-egress failed: example hostile IPv6 public egress would die at c-router-upstream-selector core-nebula ingress. CPM must emit a policyOnly delegated-public-egress ::/0 on site-c c-router-upstream-selector core-nebula via fd42:dead:cafe:1000:0:0:0:4 toward core."
    else if !siteCCoreNebulaDoesNotCarrySiteCClientOverlayDefault then
      throw "delegated-overlay-public-egress failed: example site-c Nebula core must not carry a delegated-public-egress ::/0 for c-router-access-client on overlay-east-west. Live symptom: hostile public IPv6 looped between fd42:dead:beef:ee::3 and fd42:dead:beef:ee::2 because site-c installed a public default back into Nebula."
    else if !hostileRuntimeReturnOnHostileIngress || !hostileRuntimeReturnNotOnBranchIngress then
      throw "delegated-overlay-public-egress failed: hostile runtime routed-prefix return route must be installed on b-router-policy downstr-hostile via fd42:dead:feed:1000:0:0:0:a, not on downstr-branch. Live symptom: hostile public IPv6 packets reached b-router-policy and died because the kernel selected the wrong ingress table."
    else
      throw "delegated-overlay-public-egress failed: expected b-router-core-nebula overlay-east-west to carry a policyOnly delegated-public-egress ::/0, b-router-upstream-selector core-nebula to preserve its overlay default, and b-router-upstream-selector pol-hostile-ew to route hostile delegated IPv6 default toward core-nebula for b-router-access-hostile. Remove this error only after CPM emits that ingress-lane renderer contract and live ip -6 route get from pol-hostile-ew selects core-nebula without moving underlay endpoint routes off WAN."
' >/dev/null

echo "PASS delegated-overlay-public-egress"
