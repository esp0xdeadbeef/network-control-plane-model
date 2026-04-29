#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

output_json="${tmp_dir}/output.json"
archive_json="${tmp_dir}/archive.json"

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

intent="${labs_path}/examples/s-router-test-three-site/intent.nix"
inventory="${labs_path}/examples/s-router-test-three-site/inventory-nixos.nix"

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
    siteA = data.control_plane_model.data.esp0xdeadbeef."site-a";
    siteB = data.control_plane_model.data.espbranch."site-b";

    routes4For = target: ifName:
      (((target.effectiveRuntimeRealization or { }).interfaces or { }).${ifName}.routes or { }).ipv4 or [ ];

    routes6For = target: ifName:
      (((target.effectiveRuntimeRealization or { }).interfaces or { }).${ifName}.routes or { }).ipv6 or [ ];

    hasDefaultVia = via: routes:
      builtins.any (route: (route.dst or null) == "0.0.0.0/0" && (route.via4 or null) == via) routes;

    hasDefaultVia6 = via: routes:
      builtins.any (route: (route.dst or null) == "::/0" && (route.via6 or null) == via) routes;

    hasDefault = routes:
      builtins.any (route: (route.dst or null) == "0.0.0.0/0") routes;

    hasDefault6 = routes:
      builtins.any (route: (route.dst or null) == "::/0") routes;

    siteAPolicy = siteA.runtimeTargets."esp0xdeadbeef-site-a-s-router-policy";
    branchPolicy = siteB.runtimeTargets."espbranch-site-b-b-router-policy";

    siteAEastWestDefaults =
      hasDefaultVia "10.10.0.25" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-admin--uplink-east-west")
      || hasDefaultVia "10.10.0.31" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-client--uplink-east-west")
      || hasDefaultVia "10.10.0.37" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-client2--uplink-east-west")
      || hasDefaultVia "10.10.0.43" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-mgmt--uplink-east-west");

    siteAWanDefaults =
      hasDefaultVia "10.10.0.27" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-admin--uplink-isp-a")
      && hasDefaultVia "10.10.0.29" (routes4For siteAPolicy "p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-admin--uplink-isp-b");

    branchEastWestDefault =
      hasDefaultVia "10.50.0.7" (routes4For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-branch--uplink-east-west");

    branchWanDefault =
      hasDefaultVia "10.50.0.9" (routes4For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-branch--uplink-wan");

    branchEastWestIPv6Default =
      hasDefault6 (routes6For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-branch--uplink-east-west");

    hostileEastWestIPv6Default =
      hasDefaultVia6 "fd42:dead:feed:1000:0:0:0:11" (routes6For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west");

    hostileWanIPv6Default =
      hasDefault6 (routes6For branchPolicy "p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-wan");

    siteC = data.control_plane_model.data.esp0xdeadbeef."site-c";
    siteCPolicy = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-policy";

    siteCStorageDefaults =
      hasDefault (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-mgmt--uplink-site-c-storage")
      || hasDefault (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-nas--uplink-site-c-storage")
      || hasDefault (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-printer--uplink-site-c-storage");

    siteCWanDefaults =
      hasDefaultVia "10.80.0.21" (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-mgmt--uplink-wan")
      && hasDefaultVia "10.80.0.29" (routes4For siteCPolicy "p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-iot--uplink-wan");
  in
    (!siteAEastWestDefaults)
    && siteAWanDefaults
    && (!branchEastWestDefault)
    && branchWanDefault
    && (!branchEastWestIPv6Default)
    && hostileEastWestIPv6Default
    && (!hostileWanIPv6Default)
    && (!siteCStorageDefaults)
    && siteCWanDefaults
' >/dev/null || {
  echo "FAIL preferred-uplink-defaults" >&2
  exit 1
}

echo "PASS preferred-uplink-defaults"
