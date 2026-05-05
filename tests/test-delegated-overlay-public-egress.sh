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
    coreNebula = siteB.runtimeTargets."espbranch-site-b-b-router-core-nebula";
    interfaces = coreNebula.effectiveRuntimeRealization.interfaces;

    routes6For = ifName:
      (((interfaces.${ifName} or { }).routes or { }).ipv6 or [ ]);

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
    if delegatedOverlayDefault && underlayDefaultPreserved && !badGenericOverlayDefault then
      true
    else
      throw "delegated-overlay-public-egress failed: expected b-router-core-nebula overlay-east-west to carry a policyOnly link-scoped delegated-public-egress ::/0 for b-router-access-hostile, while preserving the upstream underlay default and rejecting generic overlay defaults. Remove this error only after CPM emits that explicit renderer contract and renderer/live tests prove hostile GUA egress selects Nebula without moving underlay endpoint routes off WAN."
' >/dev/null

echo "PASS delegated-overlay-public-egress"
