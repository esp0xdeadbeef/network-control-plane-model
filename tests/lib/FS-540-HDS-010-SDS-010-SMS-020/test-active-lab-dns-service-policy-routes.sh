#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/control-plane.json"

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then
        throw "active-lab DNS policy route test: missing archived network-labs input path"
      else
        labsPath
  '
)"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/active-lab/intent.nix" \
  "${labs_path}/active-lab/inventory-clab.nix" \
  "${output_json}" >/dev/null

jq -e '
  .control_plane_model.data.esp.clab.runtimeTargets."esp-clab-clab-router-policy".effectiveRuntimeRealization.interfaces as $ifaces
  | [ "clab-router-access-admin", "clab-router-access-client", "clab-router-access-dmz", "clab-router-access-streaming" ] as $allowed_dns_clients
  | [
      $ifaces
      | to_entries[]
      | .key as $ifKey
      | .value as $iface
      | ($iface.routes.ipv4 // [])[]?
      | select(.dst == "10.50.10.1")
      | select((.intent.kind // "") == "service-endpoint-reachability")
      | select((.intent.service // "") == "clab-site-dns")
      | select((.relationId // "") == "allow-clab-site-dns-service-to-wan")
      | select(($iface.runtimeIfName // "") | startswith("up-"))
      | {
          ifKey: $ifKey,
          runtimeIfName: $iface.runtimeIfName,
          route: {dst, via4, intent, relationId, trafficType, lane, policyOnly}
        }
    ] as $wanResolverHostRoutes
  | [
      $ifaces
      | to_entries[]
      | .key as $ifKey
      | .value as $iface
      | select(($iface.runtimeIfName // "") == "down-mgmt")
      | ($iface.routes.ipv4 // [])[]?
      | select(.dst == "10.50.10.0/24")
      | select(.via4 == "10.50.0.24")
      | select((.intent.kind // "") == "service-dns-reachability")
      | select((.intent.source // "") == "service-ingress-lane")
      | select((.policyOnly // false) == true)
      | select((.lane.access // "") as $access | $allowed_dns_clients | index($access))
      | {
          ifKey: $ifKey,
          runtimeIfName: $iface.runtimeIfName,
          access: .lane.access,
          route: {dst, via4, intent, relationId, trafficType, lane, policyOnly}
        }
    ] as $dnsServiceIngressRoutes
  | ($dnsServiceIngressRoutes | map(.access) | unique | sort) as $actual_accesses
  | {
      wanResolverHostRoutes: $wanResolverHostRoutes,
      expectedAccesses: ($allowed_dns_clients | sort),
      actualAccesses: $actual_accesses,
      dnsServiceIngressRoutes: $dnsServiceIngressRoutes
    }
  | select(
      (.wanResolverHostRoutes | length) == 0
      and (.actualAccesses == (.expectedAccesses | sort))
    )
' "${output_json}" >/dev/null || {
  echo "FAIL active-lab DNS policy routes: clab-site-dns must route through down-mgmt in each allowed DNS client policy table, not through WAN/up-* interfaces" >&2
  jq '
    .control_plane_model.data.esp.clab.runtimeTargets."esp-clab-clab-router-policy".effectiveRuntimeRealization.interfaces
    | to_entries[]
    | select((.value.runtimeIfName // "") as $ifname | ($ifname == "down-mgmt" or ($ifname | startswith("up-"))))
    | {
        ifKey: .key,
        runtimeIfName: .value.runtimeIfName,
        routes: [
          (.value.routes.ipv4 // [])[]?
          | select(.dst == "10.50.10.0/24" or .dst == "10.50.10.1")
          | {dst, via4, intent, relationId, trafficType, lane, policyOnly, reason}
        ]
      }
  ' "${output_json}" >&2
  exit 1
}

echo "PASS active-lab DNS service policy routes"
