#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-OVERLAY-UPSTREAM-DEFAULT-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

archive_json="${work_dir}/archive.json"
output_json="${work_dir}/cpm.json"

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

example_dir="${labs_path}/examples/s-router-overlay-dns-lane-policy"
nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${example_dir}/intent.nix" \
  "${example_dir}/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -e '
  def default_routes($routes): $routes[]? | select(.dst == "0.0.0.0/0" or .dst == "::/0");
  def lane_accesses($routes; $uplink):
    [default_routes($routes)
      | select((.lane.uplink // "") == $uplink and (.lane.access // null) != null)
      | .lane.access] | unique | sort;
  def has_default($routes; $access; $uplink):
    any(default_routes($routes);
      (.policyOnly // false) == true
      and (.reason // "") == "policy-derived-default"
      and (.lane.access // "") == $access
      and (.lane.uplink // "") == $uplink);
  def has_unscoped_default_to($routes; $via):
    any(default_routes($routes);
      (.lane.access // null) == null
      and ((.via4 // .via6 // "") == $via));
  def first_lane_via($routes; $access; $uplink):
    [default_routes($routes)
      | select((.lane.access // "") == $access and (.lane.uplink // "") == $uplink)
      | (.via4 // .via6 // "")] | sort | .[0];

  .control_plane_model.data as $root
  | $root.esp0xdeadbeef["site-a"].runtimeTargets."esp0xdeadbeef-site-a-s-router-upstream-selector".effectiveRuntimeRealization.interfaces as $siteAUp
  | ($siteAUp."p2p-s-router-core-isp-a-s-router-upstream-selector".routes.ipv4 + $siteAUp."p2p-s-router-core-isp-a-s-router-upstream-selector".routes.ipv6) as $ispA
  | ($siteAUp."p2p-s-router-core-isp-b-s-router-upstream-selector".routes.ipv4 + $siteAUp."p2p-s-router-core-isp-b-s-router-upstream-selector".routes.ipv6) as $ispB
  | ($siteAUp."p2p-s-router-core-nebula-s-router-upstream-selector".routes.ipv4 + $siteAUp."p2p-s-router-core-nebula-s-router-upstream-selector".routes.ipv6) as $eastWestA
  | (["s-router-access-admin","s-router-access-client","s-router-access-client2","s-router-access-mgmt","s-router-access-streaming"] | sort) as $normalSiteA
  | (lane_accesses($ispA; "isp-a") == $normalSiteA)
    and (lane_accesses($ispB; "isp-b") == $normalSiteA)
    and (lane_accesses($eastWestA; "east-west") == ["s-router-access-admin","s-router-access-client","s-router-access-client2","s-router-access-mgmt"])

  | . and (
      $root.esp0xdeadbeef["site-c"].runtimeTargets."esp0xdeadbeef-site-c-c-router-policy".effectiveRuntimeRealization.interfaces
      ."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-client--uplink-east-west".routes as $siteCPolicyClientEw
      | has_default(($siteCPolicyClientEw.ipv4 + $siteCPolicyClientEw.ipv6); "c-router-access-client"; "east-west")
    )

  | . and (
      $root.esp0xdeadbeef["site-c"].runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector".effectiveRuntimeRealization.interfaces
      ."p2p-c-router-nebula-core-c-router-upstream-selector".routes as $siteCUpstreamEw
      | has_default(($siteCUpstreamEw.ipv4 + $siteCUpstreamEw.ipv6); "c-router-access-client"; "east-west")
    )

  | . and (
      $root.espbranch["site-b"].runtimeTargets."espbranch-site-b-b-router-upstream-selector".effectiveRuntimeRealization.interfaces
      ."p2p-b-router-core-nebula-b-router-upstream-selector".routes as $branchUpstreamEw
      | has_default(($branchUpstreamEw.ipv4 + $branchUpstreamEw.ipv6); "b-router-access-hostile"; "east-west")
    )

  | . and (
      $root.espbranch["site-b"].runtimeTargets."espbranch-site-b-b-router-upstream-selector".effectiveRuntimeRealization.interfaces
      ."p2p-b-router-core-nebula-b-router-upstream-selector".routes as $branchUpstreamEw
      | first_lane_via(($branchUpstreamEw.ipv6 // []); "b-router-access-hostile"; "east-west") as $hostileVia6
      | has_unscoped_default_to(($branchUpstreamEw.ipv6 // []); $hostileVia6) | not
    )
' "${output_json}" >/dev/null

echo "PASS example-overlay-upstream-policy-defaults-preserved"
