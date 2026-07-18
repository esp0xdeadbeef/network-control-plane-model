#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-UNDERLAY-DYNAMIC-CLIENT-001
# GAMP-SCOPE: software-module-test
set -euo pipefail
# LAB-SMT-ID: LAB-SMT-010
# LAB-SMT-SCOPE: examples-only; see network-labs/tests/SMT.md

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
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
      if labsPath == null then throw "tests: missing archived network-labs input path" else labsPath
  '
)"

assert_dynamic_client_addressing() {
  local site_name="$1"
  local target_name="$2"

  nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${labs_path}/examples/tri-site-s-router-overlay-egress/intent.nix" \
    "${labs_path}/examples/tri-site-s-router-overlay-egress/inventory.nix" \
    "${output_json}" >/dev/null

  jq -e --arg site_name "${site_name}" --arg target_name "${target_name}" '
    .control_plane_model.data.esp[$site_name].runtimeTargets[$target_name]
    .effectiveRuntimeRealization.interfaces."tenant-client" as $iface
    | ($iface.dynamicAddressing
      | .ipv4.enable == true
        and .ipv4.method == "dhcp"
        and .ipv4.dhcp == true
        and .ipv6.enable == true
        and .ipv6.method == "slaac"
        and .ipv6.acceptRA == true)
      and (($iface.delegatedPrefixes // []) == [])
      and (($iface.delegatedPrefixAuthority // null) == null)
      and (($iface.bridge // null) == null)
      and (($iface.bridgeName // null) == null)
      and (($iface.bridgeOwner // false) == false)
      and (($iface.trunk // null) == null)
      and (($iface.trunkVlans // []) == [])
      and (($iface.vlans // []) == [])
      and ((.control_plane_model.data.esp[$site_name].runtimeTargets[$target_name].runtimeOriginEgress // null) == null)
      and ((.control_plane_model.data.esp[$site_name].runtimeTargets[$target_name].services.dns.outgoingInterfaces // []) == [])
      and ((.control_plane_model.data.esp[$site_name].runtimeTargets[$target_name].services.dns.roles.recursion.outgoingInterfaces // []) == [])
  ' "${output_json}" >/dev/null || {
    cat >&2 <<EOF
FAIL overlay-underlay-access-dynamic-client-addressing: ${target_name} tenant-client must carry explicit DHCP/SLAAC dynamicAddressing in CPM.

The overlay underlay core is realized as a host-like tenant client. It must not
emit delegated-prefix, bridge, trunk, or loopback-sourced runtime-origin
authority from the simple LAN attachment.
EOF
    return 1
  }
}

assert_dynamic_client_addressing "home" "esp-home-example-router-core-nebula"
assert_dynamic_client_addressing "lab" "esp-lab-example-router-core-nebula"

echo "PASS overlay-underlay-access-dynamic-client-addressing"
