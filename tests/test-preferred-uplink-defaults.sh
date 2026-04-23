#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
intent="${repo_root}/../nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/profiles/dual-wan-branch/intent.nix"
inventory="${repo_root}/../nixos/nixos/virtual-machine/nixos-shell-vm/s-router-test/profiles/dual-wan-branch/bgp-inventory.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

output_json="${tmp_dir}/output.json"

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

    hasDefaultVia = via: routes:
      builtins.any (route: (route.dst or null) == "0.0.0.0/0" && (route.via4 or null) == via) routes;

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
  in
    (!siteAEastWestDefaults) && siteAWanDefaults && (!branchEastWestDefault) && branchWanDefault
' >/dev/null || {
  echo "FAIL preferred-uplink-defaults" >&2
  exit 1
}

echo "PASS preferred-uplink-defaults"
