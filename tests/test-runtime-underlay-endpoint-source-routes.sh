#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-UNDERLAY-SOURCE-ROUTES-001
# GAMP-SCOPE: software-module-test
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
  "${labs_path}/examples/tri-site-s-router-overlay-egress/intent.nix" \
  "${labs_path}/examples/tri-site-s-router-overlay-egress/inventory.nix" \
  "${output_json}" >/dev/null

jq -e '
  def routes_for($iface; $family):
    if $family == 4 then (($iface.value.routes // {}).ipv4 // []) else (($iface.value.routes // {}).ipv6 // []) end;
  def default_dst($family):
    if $family == 4 then "0.0.0.0/0" else "::/0" end;
  def iface_has_family_default($iface; $family):
    any(routes_for($iface; $family)[]?; (.dst // null) == default_dst($family));
  def endpoint_routes($target; $endpoint):
    (($target.effectiveRuntimeRealization // {}).interfaces // {})
    | to_entries
    | [
        .[] as $iface
        | routes_for($iface; $endpoint.family)[]
        | select(
            (.sourceFile // null) == $endpoint.sourceFile
            and (.family // null) == $endpoint.family
            and (.proto // null) == "underlay"
            and (.intent.kind // null) == "overlay-underlay-reachability"
          )
        | { iface: $iface.key, onDefaultBearingInterface: iface_has_family_default($iface; $endpoint.family) }
      ];
  [
    .control_plane_model.data
    | to_entries[] as $enterprise
    | $enterprise.value
    | to_entries[] as $site
    | (($site.value.overlays // {}) | to_entries[] | .value.underlayEndpoints[]?)
  ] as $allEndpoints
  | [
      .control_plane_model.data
      | to_entries[] as $enterprise
      | $enterprise.value
      | to_entries[] as $site
      | (($site.value.overlays // {}) | to_entries[] | .value.underlayEndpoints[]?) as $endpoint
      | [
          ($site.value.runtimeTargets // {})
          | to_entries[]
          | {
              target: .key,
              routes: endpoint_routes(.value; $endpoint)
            }
          | select((.routes | length) > 0)
        ] as $hits
      | {
          sourceFile: $endpoint.sourceFile,
          family: $endpoint.family,
          hasHit: ($hits | length > 0),
          valid: all($hits[]; all(.routes[]; .onDefaultBearingInterface))
        }
    ] as $checks
  | ($allEndpoints | length) > 0
  and all($checks[]; .hasHit and .valid)
' "${output_json}" >/dev/null || {
  echo "FAIL runtime-underlay-endpoint-source-routes: each modeled overlay underlay endpoint sourceFile route must appear and stay on default-bearing underlay interfaces" >&2
  exit 1
}

jq -e '
  def routes_for($iface; $family):
    if $family == 4 then (($iface.value.routes // {}).ipv4 // []) else (($iface.value.routes // {}).ipv6 // []) end;
  def default_dst($family):
    if $family == 4 then "0.0.0.0/0" else "::/0" end;
  def iface_has_family_default($iface; $family):
    any(routes_for($iface; $family)[]?; (.dst // null) == default_dst($family));
  def endpoint_routes($target; $endpoint):
    (($target.effectiveRuntimeRealization // {}).interfaces // {})
    | to_entries[]
    | . as $iface
    | routes_for($iface; $endpoint.family)[]
    | select(
        (.sourceFile // null) == $endpoint.sourceFile
        and (.family // null) == $endpoint.family
        and (.proto // null) == "underlay"
        and (.intent.kind // null) == "overlay-underlay-reachability"
      )
    | { iface: $iface.key, onDefaultBearingInterface: iface_has_family_default($iface; $endpoint.family) };
  [
    .control_plane_model.data
    | to_entries[] as $enterprise
    | $enterprise.value
    | to_entries[] as $site
    | (($site.value.overlays // {}) | to_entries[] | .value.underlayEndpoints[]?) as $endpoint
    | ($site.value.runtimeTargets // {})
    | to_entries[]
    | endpoint_routes(.value; $endpoint)
  ]
  | all(.[]; .onDefaultBearingInterface)
' "${output_json}" >/dev/null || {
  echo "FAIL runtime-underlay-endpoint-source-routes: an overlay underlay endpoint sourceFile route landed on an interface without a modeled default" >&2
  exit 1
}

echo "PASS runtime-underlay-endpoint-source-routes"
