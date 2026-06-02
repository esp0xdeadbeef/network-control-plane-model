#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-OVERLAY-DNS-RETURN-001
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
      if labsPath == null then throw "example-overlay-dns-return-table: missing network-labs input" else labsPath
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
  .control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector"
    .effectiveRuntimeRealization.interfaces."p2p-c-router-nebula-core-c-router-upstream-selector"
    .routes.ipv4 as $routes
  | any($routes[]?;
      .dst == "10.70.10.0/24"
      and .via4 == "10.80.0.10"
      and .policyOnly == true
      and .lane.access == "c-router-access-dmz"
      and .lane.uplink == "east-west"
      and .intent.kind == "overlay-reachability"
      and .intent.policyTableComplement == true)
' "${output_json}" >/dev/null || {
  cat >&2 <<'EOF'
FAIL example-overlay-dns-return-table

CPM must emit a renderer-neutral policy-table complement route for the Site-C
DNS service return path: replies from the DMZ DNS service to the remote hostile
prefix must return through the Nebula core interface in the east-west DMZ lane.
EOF
  jq '
    .control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector"
      .effectiveRuntimeRealization.interfaces."p2p-c-router-nebula-core-c-router-upstream-selector"
      .routes.ipv4
  ' "${output_json}" >&2
  exit 1
}

echo "PASS example-overlay-dns-return-table"
