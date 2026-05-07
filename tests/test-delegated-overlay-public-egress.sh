#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"
lab_inventory="${tmp_dir}/lab-inventory.nix"
lab_output_json="${tmp_dir}/lab-output.json"

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

printf 'import "%s/labs/lab-s-sigma/s-router-test-three-site/getResolvedInventory.nix" { renderer = "nixos"; }\n' "${labs_path}" > "${lab_inventory}"
(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/labs/lab-s-sigma/s-router-test-three-site/intent.nix" \
    "${lab_inventory}" \
    "${lab_output_json}" >/dev/null
)

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    siteB = data.control_plane_model.data.espbranch."site-b";
    coreNebula = siteB.runtimeTargets."espbranch-site-b-b-router-core-nebula";
    upstreamSelector = siteB.runtimeTargets."espbranch-site-b-b-router-upstream-selector";
    interfaces = coreNebula.effectiveRuntimeRealization.interfaces;
    upstreamInterfaces = upstreamSelector.effectiveRuntimeRealization.interfaces;

    routes6For = ifName:
      (((interfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);
    upstreamRoutes6For = ifName:
      (((upstreamInterfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);

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
  in
    if delegatedOverlayDefault && upstreamDelegatedDefaultToOverlay && hostilePolicyIngressDelegatedDefaultToOverlay && underlayDefaultPreserved && !badGenericOverlayDefault then
      true
    else
      throw "delegated-overlay-public-egress failed: expected b-router-core-nebula overlay-east-west to carry a policyOnly delegated-public-egress ::/0, b-router-upstream-selector core-nebula to preserve its overlay default, and b-router-upstream-selector pol-hostile-ew to route hostile delegated IPv6 default toward core-nebula for b-router-access-hostile. Remove this error only after CPM emits that ingress-lane renderer contract and live ip -6 route get from pol-hostile-ew selects core-nebula without moving underlay endpoint routes off WAN."
' >/dev/null

OUTPUT_JSON="${lab_output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    siteB = data.control_plane_model.data.espbranch."site-b";
    coreNebula = siteB.runtimeTargets."espbranch-site-b-b-router-core-nebula";
    routes6 =
      coreNebula.effectiveRuntimeRealization.interfaces."overlay-east-west".routes.ipv6 or [ ];

    delegatedDefaultToSiteC =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.policyOnly or false) == true
          && (route.proto or null) == "overlay"
          && (route.overlay or null) == "east-west"
          && (route.peerSite or null) == "esp0xdeadbeef.site-c"
          && (route.family or null) == 6
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "b-router-access-hostile")
        routes6;
  in
    if delegatedDefaultToSiteC then
      true
    else
      throw "delegated-overlay-public-egress failed: lab-s-sigma branch delegated IPv6 public egress reaches b-router-core-nebula but the overlay route lacks explicit overlay=east-west peerSite=esp0xdeadbeef.site-c family=6 metadata for Nebula unsafe-route materialization. Remove this error only after CPM emits the route owner contract and live hostile IPv6 internet no longer dies with ICMP unreachable from b-router-core-nebula."
' >/dev/null

echo "PASS delegated-overlay-public-egress"
