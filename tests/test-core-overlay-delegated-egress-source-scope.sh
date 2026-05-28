#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-NEBULA-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
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

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
    "${output_json}" >/dev/null
)

jq -e '
  .control_plane_model.data.espbranch["site-b"].runtimeTargets["espbranch-site-b-b-router-core-nebula"] as $target
  | ($target.forwardingIntent.rules // []) as $rules
  | {
      has_hostile_v4_source_rule: any($rules[];
        (.action // "") == "accept"
        and (.fromInterface // "") == "upstream"
        and (.toInterface // "") == "nebula1"
        and ((.intent.kind // "") == "delegated-public-egress")
        and any((.sourcePrefixes // [])[]?; (.family // 4) == 4 and (.prefix // "") == "10.70.10.0/24")
      ),
      has_hostile_ula_source_rule: any($rules[];
        (.action // "") == "accept"
        and (.fromInterface // "") == "upstream"
        and (.toInterface // "") == "nebula1"
        and ((.intent.kind // "") == "delegated-public-egress")
        and any((.sourcePrefixes // [])[]?; (.family // 4) == 6 and ((.prefix // "") | test("^fd42:dead:feed:(0070|70):|^fd42:dead:feed:(0070|70)::/64$")))
      ),
      has_hostile_runtime_source_file_rule: any($rules[];
        (.action // "") == "accept"
        and (.fromInterface // "") == "upstream"
        and (.toInterface // "") == "nebula1"
        and ((.intent.kind // "") == "delegated-public-egress")
        and (.family // null) == 6
        and any((.sourceFiles // [])[]?; . == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile")
      ),
      has_unscoped_underlay_to_overlay_accept: any($rules[];
        (.action // "") == "accept"
        and (.fromInterface // "") == "upstream"
        and (.toInterface // "") == "nebula1"
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
    .control_plane_model.data.espbranch["site-b"].runtimeTargets["espbranch-site-b-b-router-core-nebula"].forwardingIntent.rules // []
    | map(select((.fromInterface // "") == "upstream" or (.toInterface // "") == "nebula1"))
  ' "${output_json}" >&2
  echo "FAIL core-overlay-delegated-egress-source-scope: core-nebula must emit source-scoped upstream -> provider overlay forwarding for hostile delegated public egress, without an unscoped underlay-to-overlay accept" >&2
  exit 1
}

echo "PASS core-overlay-delegated-egress-source-scope"
