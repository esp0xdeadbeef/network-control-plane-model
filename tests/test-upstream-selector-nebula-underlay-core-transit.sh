#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_json="$(mktemp)"
output_json="$(mktemp)"
violations_json="$(mktemp)"
trap 'rm -f "${archive_json}" "${output_json}" "${violations_json}"' EXIT

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
  .control_plane_model.data
  | [
      to_entries[] as $enterprise
      | $enterprise.value
      | to_entries[] as $site
      | $site.value.runtimeTargets
      | to_entries[]
      | select((.value.role // "") == "upstream-selector")
      | (.value.forwardingIntent.rules // [])[]
      | select(
          (.action == "accept")
          and (.fromInterface == "core-nebula")
          and (.toInterface == "core-isp")
          and ((.trafficType // "any") == "any")
        )
    ]
  | length == 0
' "${output_json}" >/dev/null || {
  cat >&2 <<'EOF'
FAIL upstream-selector nebula underlay core transit.

Overlay ingress must not get a broad upstream-selector firewall allowance to
the WAN core. Underlay endpoint reachability may only open the modeled Nebula
traffic type when the matching overlay-underlay endpoint route exists.
EOF
  exit 1
}

jq -e '
  .control_plane_model.data
  | [
      to_entries[] as $enterprise
      | $enterprise.value
      | to_entries[] as $site
      | $site.value.runtimeTargets
      | to_entries[]
      | select((.value.role // "") == "upstream-selector")
      | (.value.forwardingIntent.rules // [])[]
      | select(
          (.action == "accept")
          and (.fromInterface == "core-nebula")
          and (.toInterface == "core-isp")
          and (.trafficType == "nebula-storage")
          and (.relationId == "allow-siteb-nebula-underlay-to-wan")
          and (.intent.kind == "overlay-underlay-reachability")
          and (.intent.source == "overlay-underlay-endpoint")
          and (.intent.overlay == "east-west")
        )
    ]
  | length == 1
' "${output_json}" >/dev/null || {
  cat >&2 <<'EOF'
FAIL upstream-selector nebula underlay core transit.

Expected one narrow core-nebula -> core-isp firewall allowance for modeled
Nebula underlay endpoint reachability. The rule must carry the Nebula traffic
type and overlay-underlay endpoint intent so it cannot become a generic WAN
bypass.
EOF
  exit 1
}

echo "PASS upstream-selector-nebula-underlay-core-transit"
