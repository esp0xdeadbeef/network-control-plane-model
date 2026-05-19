#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
archive_json="$(mktemp)"
output_json="$(mktemp)"
trap 'rm -f "${archive_json}" "${output_json}"' EXIT

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then throw "tests: missing archived network-labs input path" else labsPath
  '
)"

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -e '
  .control_plane_model.data.espbranch."site-b" as $site
  | $site.overlays."east-west".underlayEndpoints as $endpoints
  | $site.runtimeTargets."espbranch-site-b-b-router-upstream-selector"
    .effectiveRuntimeRealization.interfaces
    ."p2p-b-router-core-simulated-isp-b-router-upstream-selector".routes as $routes
  | def hasRoute($endpoint):
      if $endpoint.family == 4 then
        any($routes.ipv4[]?;
          .sourceFile == $endpoint.sourceFile
          and .family == 4
          and .via4 == "10.50.0.6"
          and .proto == "underlay"
          and .intent.kind == "overlay-underlay-reachability")
      elif $endpoint.family == 6 then
        any($routes.ipv6[]?;
          .sourceFile == $endpoint.sourceFile
          and .family == 6
          and .via6 == "fd42:dead:feed:1000:0:0:0:6"
          and .proto == "underlay"
          and .intent.kind == "overlay-underlay-reachability")
      else
        false
      end;
    ($endpoints | length) > 0
    and all($endpoints[]; hasRoute(.))
' "${output_json}" >/dev/null || {
  echo "FAIL runtime-underlay-endpoint-source-routes: upstream selector must route explicit runtime underlay endpoint secrets toward the WAN core" >&2
  exit 1
}

jq -e '
  .control_plane_model.data.esp0xdeadbeef."site-a" as $site
  | $site.overlays."east-west".underlayEndpoints as $endpoints
  | $site.runtimeTargets."esp0xdeadbeef-site-a-s-router-core-nebula"
    .effectiveRuntimeRealization.interfaces
    ."p2p-s-router-core-nebula-s-router-upstream-selector".routes as $routes
  | def hasRoute($endpoint):
      if $endpoint.family == 4 then
        any($routes.ipv4[]?;
          .sourceFile == $endpoint.sourceFile
          and .family == 4
          and .via4 == "10.10.0.17"
          and .proto == "underlay"
          and .intent.kind == "overlay-underlay-reachability")
      elif $endpoint.family == 6 then
        any($routes.ipv6[]?;
          .sourceFile == $endpoint.sourceFile
          and .family == 6
          and .via6 == "fd42:dead:beef:1000:0:0:0:11"
          and .proto == "underlay"
          and .intent.kind == "overlay-underlay-reachability")
      else
        false
      end;
    ($endpoints | length) > 0
    and all($endpoints[]; hasRoute(.))
' "${output_json}" >/dev/null || {
  echo "FAIL runtime-underlay-endpoint-source-routes: overlay core must route explicit runtime underlay endpoint secrets toward its uplink-lane upstream peer before overlay split-default routes" >&2
  exit 1
}

echo "PASS runtime-underlay-endpoint-source-routes"
