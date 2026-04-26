#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

archive_json="$(mktemp)"
output_json="$(mktemp)"
trap 'rm -f "'"${archive_json}"'" "'"${output_json}"'"' EXIT

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
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

intent_path="${labs_path}/examples/s-router-test-three-site/intent.nix"
inventory_path="${labs_path}/examples/s-router-test-three-site/inventory-nixos.nix"

nix run "${repo_root}#compile-and-build-control-plane-model" -- "${intent_path}" "${inventory_path}" "${output_json}" >/dev/null

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    siteB = data.control_plane_model.data.espbranch."site-b";
    hostileEw =
      siteB.runtimeTargets."espbranch-site-b-b-router-policy"
        .effectiveRuntimeRealization.interfaces
        ."p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west".routes;
    hostileAccessAds =
      siteB.runtimeTargets."espbranch-site-b-b-router-access-hostile".advertisements.ipv6Ra;
    hasDst = routes: destination:
      builtins.any (route: (route.dst or null) == destination) (routes.ipv4 or [ ])
      || builtins.any (route: (route.dst or null) == destination) (routes.ipv6 or [ ]);
  in
    hasDst hostileEw "10.20.10.0/24"
    && hasDst hostileEw "fd42:dead:beef:0010:0000:0000:0000:0000/64"
    && (hostileAccessAds != [ ])
    && (builtins.head hostileAccessAds).prefixes == [ "2a01:4f8:1c17:b337::/64" ]
    && (builtins.head hostileAccessAds).routerInterface.subnet6 == "fd42:dead:feed:70::/64"
' | grep -qx true

echo "PASS hostile-dns-east-west"
