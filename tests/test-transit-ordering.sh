#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_json="$(mktemp)"
output_json="$(mktemp)"
trap 'rm -f "${archive_json}" "${output_json}"' EXIT

nix flake archive --json "path:${repo_root}" > "${archive_json}"
labs_path="$(jq -er '.inputs["network-labs"].path' "${archive_json}")"
intent_path="${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix"
inventory_path="${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix"

[[ -f "${intent_path}" ]] || { echo "missing intent fixture: ${intent_path}" >&2; exit 1; }
[[ -f "${inventory_path}" ]] || { echo "missing inventory fixture: ${inventory_path}" >&2; exit 1; }

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" "${inventory_path}" "${output_json}" >/dev/null

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));

    hasPrefix = str:
      builtins.match "^link::.*" str != null;

    uniqueLength =
      xs:
      builtins.length (
        builtins.attrNames (
          builtins.listToAttrs (builtins.map (x: { name = x; value = true; }) xs)
        )
      );

    sorted =
      xs: builtins.sort (a: b: a < b) xs;

    validForSite =
      site:
      let
        transit = site.transit or { };
        ordering = transit.ordering or [ ];
        adjacencies = transit.adjacencies or [ ];
        adjacencyIds = builtins.map (entry: entry.id or null) adjacencies;
      in
        builtins.isList ordering
        && builtins.isList adjacencies
        && builtins.length ordering > 0
        && builtins.all hasPrefix ordering
        && builtins.length ordering == builtins.length adjacencyIds
        && builtins.length ordering == uniqueLength ordering
        && sorted ordering == sorted adjacencyIds;

    allSites =
      builtins.concatMap
        (enterprise: builtins.attrValues enterprise)
        (builtins.attrValues data.control_plane_model.data);

    allValid = builtins.all validForSite allSites;
  in
    allValid
' | grep -qx true

echo "PASS transit-ordering"
