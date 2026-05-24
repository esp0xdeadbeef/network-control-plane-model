#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
inventory_nixos="${tmp_dir}/resolved-inventory-nixos.nix"
inventory_clab="${tmp_dir}/resolved-inventory-clab.nix"
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

cat >"${inventory_nixos}" <<EOF
import ${labs_path}/labs/lab-s-sigma/s-router-test-three-site/getResolvedInventory.nix { renderer = "nixos"; }
EOF

cat >"${inventory_clab}" <<EOF
import ${labs_path}/labs/lab-s-sigma/s-router-test-three-site/getResolvedInventory.nix { renderer = "clab"; }
EOF

assert_dynamic_client_addressing() {
  local inventory_path="$1"
  local target_name="$2"

  nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${labs_path}/labs/lab-s-sigma/s-router-test-three-site/intent.nix" \
    "${inventory_path}" \
    "${output_json}" >/dev/null

  jq -e --arg target_name "${target_name}" '
    .control_plane_model.data.esp
    | [
        to_entries[]
        | (.value.runtimeTargets[$target_name] // null)
        | select(. != null)
        | .effectiveRuntimeRealization.interfaces."tenant-client".dynamicAddressing
      ] as $matches
    | ($matches | length) == 1
      and all($matches[];
        .ipv4.enable == true
        and .ipv4.method == "dhcp"
        and .ipv4.dhcp == true
        and .ipv6.enable == true
        and .ipv6.method == "slaac"
        and .ipv6.acceptRA == true
      )
  ' "${output_json}" >/dev/null || {
    cat >&2 <<EOF
FAIL overlay-underlay-access-dynamic-client-addressing: ${target_name} tenant-client must carry explicit DHCP/SLAAC dynamicAddressing in CPM.

The overlay underlay core is realized as a host-like tenant client, not as a
static p2p link. Renderers need this explicit contract from CPM so they do not
infer DHCP/RA behavior from missing addr4/addr6 fields or node names.
EOF
    return 1
  }
}

assert_dynamic_client_addressing "${inventory_nixos}" "esp-nixos-router-core-nebula"
assert_dynamic_client_addressing "${inventory_clab}" "esp-clab-router-core-nebula"

echo "PASS overlay-underlay-access-dynamic-client-addressing"
