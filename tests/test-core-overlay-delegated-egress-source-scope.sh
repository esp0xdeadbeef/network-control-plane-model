#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
inventory_nix="${tmp_dir}/inventory-nixos.nix"
output_json="${tmp_dir}/output.json"

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "core-overlay-delegated-egress-source-scope: missing network-labs input" else labsPath
  '
)"

printf 'import %s/labs/lab-s-sigma/s-router-test-three-site/getResolvedInventory.nix { renderer = "nixos"; }\n' "${labs_path}" > "${inventory_nix}"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/labs/lab-s-sigma/s-router-test-three-site/intent.nix" \
    "${inventory_nix}" \
    "${output_json}" >/dev/null
)

jq -e '
  .control_plane_model.data.esp.nixos.runtimeTargets["esp-nixos-router-core-nebula"] as $target
  | ($target.forwardingIntent.rules // []) as $rules
  | {
      has_hostile_v4_source_rule: any($rules[];
        (.action // "") == "accept"
        and (.fromInterface // "") == "upstream"
        and (.toInterface // "") == "overlay-west"
        and ((.intent.kind // "") == "delegated-public-egress")
        and any((.sourcePrefixes // [])[]?; (.family // 4) == 4 and (.prefix // "") == "10.20.70.0/24")
      ),
      has_hostile_ula_source_rule: any($rules[];
        (.action // "") == "accept"
        and (.fromInterface // "") == "upstream"
        and (.toInterface // "") == "overlay-west"
        and ((.intent.kind // "") == "delegated-public-egress")
        and any((.sourcePrefixes // [])[]?; (.family // 4) == 6 and ((.prefix // "") | test("^fd42:dead:beef:(0070|70):|^fd42:dead:beef:(0070|70)::/64$")))
      ),
      has_hostile_runtime_source_file_rule: any($rules[];
        (.action // "") == "accept"
        and (.fromInterface // "") == "upstream"
        and (.toInterface // "") == "overlay-west"
        and ((.intent.kind // "") == "delegated-public-egress")
        and (.family // null) == 6
        and any((.sourceFiles // [])[]?; . == "/run/secrets/access-node-ipv6-prefix-esp-nixos-router-access-hostile")
      ),
      has_unscoped_underlay_to_overlay_accept: any($rules[];
        (.action // "") == "accept"
        and (.fromInterface // "") == "upstream"
        and (.toInterface // "") == "overlay-west"
        and ((.sourcePrefixes // []) == [])
        and ((.sourceFiles // []) == [])
      )
    }
  | select(
      .has_hostile_v4_source_rule
      and .has_hostile_ula_source_rule
      and .has_hostile_runtime_source_file_rule
      and (.has_unscoped_underlay_to_overlay_accept | not)
    )
' "${output_json}" >/dev/null || {
  jq '
    .control_plane_model.data.esp.nixos.runtimeTargets["esp-nixos-router-core-nebula"].forwardingIntent.rules // []
    | map(select((.fromInterface // "") == "upstream" or (.toInterface // "") == "overlay-west"))
  ' "${output_json}" >&2
  echo "FAIL core-overlay-delegated-egress-source-scope: core-nebula must emit source-scoped upstream -> overlay-west forwarding for hostile delegated public egress, without an unscoped underlay-to-overlay accept" >&2
  exit 1
}

echo "PASS core-overlay-delegated-egress-source-scope"
