#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"

nix flake archive --json "path:${repo_root}" >"${archive_json}"

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

intent="${labs_path}/examples/single-wan-uplink-static-egress/intent.nix"
inventory="${labs_path}/examples/single-wan-uplink-static-egress/inventory-clab.nix"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${intent}" \
    "${inventory}" \
    "${output_json}" >/dev/null
)

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    core = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-core-wan";
    wan = core.effectiveRuntimeRealization.interfaces.wan;

    hasStaticDefault4 =
      builtins.any
        (route:
          (route.dst or null) == "0.0.0.0/0"
          && (route.via4 or null) == "192.0.2.1"
          && (route.proto or null) == "upstream"
          && ((route.intent or { }).source or null) == "explicit-uplink-static")
        (wan.routes.ipv4 or [ ]);
  in
    if hasStaticDefault4 then
      true
    else
      throw "static uplink egress route missing: expected core WAN runtime interface to carry 0.0.0.0/0 via 192.0.2.1 from inventory.controlPlane.sites.*.uplinks.*.egress.static.routes"
' >/dev/null

echo "PASS static-uplink-egress-routes"
