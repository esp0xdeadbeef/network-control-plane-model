#!/usr/bin/env bash
set -euo pipefail

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

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/tri-site-s-router-overlay-egress/intent.nix" \
  "${labs_path}/examples/tri-site-s-router-overlay-egress/inventory.nix" \
  "${output_json}" >/dev/null

jq -e '
  def is_hostile_ula:
    . == "fd42:dead:beef:70::/64"
    or . == "fd42:dead:beef:0070:0000:0000:0000:0000/64";

  .control_plane_model.data.esp.home.runtimeTargets."esp-home-example-router-core-nebula"
    .effectiveRuntimeRealization.interfaces."p2p-home-example-router-core-nebula-home-example-router-upstream"
    .routes as $routes
  | any($routes.ipv4[]?;
      .dst == "10.20.70.0/24"
      and .via4 == "10.10.0.17"
      and .proto == "internal"
      and .intent.kind == "internal-reachability")
    and any($routes.ipv6[]?;
      (.dst | is_hostile_ula)
      and .via6 == "fd42:dead:beef:1000:0:0:0:11"
      and .proto == "internal"
      and .intent.kind == "internal-reachability")
    and any($routes.ipv6[]?;
      .sourceFile == "/run/secrets/access-node-ipv6-prefix-esp-home-example-router-access-hostile"
      and .via6 == "fd42:dead:beef:1000:0:0:0:11"
      and .proto == "internal"
      and .intent.kind == "runtime-routed-prefix-return")
' "${output_json}" >/dev/null || {
  cat >&2 <<'EOF'
FAIL overlay-core-local-hostile-return-routes

CPM must preserve NFM's local overlay-edge return routes for hostile IPv4,
hostile ULA, and runtime delegated hostile GUA on the real core-nebula upstream
leg. Renderers must not recover these routes from names or local runtime hacks.
EOF
  jq '
    .control_plane_model.data.esp.home.runtimeTargets."esp-home-example-router-core-nebula"
      .effectiveRuntimeRealization.interfaces."p2p-home-example-router-core-nebula-home-example-router-upstream"
      .routes
  ' "${output_json}" >&2
  exit 1
}

echo "PASS overlay-core-local-hostile-return-routes"
