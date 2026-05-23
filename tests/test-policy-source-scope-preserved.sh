#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

archive_json="${work_dir}/archive.json"
output_json="${work_dir}/cpm.json"
gron_txt="${work_dir}/cpm.gron"

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

gron "${output_json}" >"${gron_txt}"

require_gron() {
  local pattern="$1"
  if ! rg -q --fixed-strings "${pattern}" "${gron_txt}"; then
    echo "FAIL policy-source-scope-preserved: missing gron line: ${pattern}" >&2
    exit 1
  fi
}

require_gron 'json.control_plane_model.data.espbranch["site-b"].tenantPrefixOwners["4|10.70.10.0/24"].owner = "b-router-access-hostile";'
require_gron 'json.control_plane_model.data.espbranch["site-b"].tenantPrefixOwners["6|source:/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"].owner = "b-router-access-hostile";'

jq -e '
  def route_has($access; $uplink; $dst):
    [.control_plane_model.data.espbranch["site-b"].runtimeTargets."espbranch-site-b-b-router-policy"
      .effectiveRuntimeRealization.interfaces[]
      .routes.ipv4[]?, .control_plane_model.data.espbranch["site-b"].runtimeTargets."espbranch-site-b-b-router-policy"
      .effectiveRuntimeRealization.interfaces[]
      .routes.ipv6[]?
      | select(
          (.policyOnly // false) == true
          and (.reason // "") == "policy-derived-default"
          and (.lane.access // "") == $access
          and (.lane.uplink // "") == $uplink
          and (.dst // "") == $dst
        )] | length > 0;
  .control_plane_model.data.espbranch["site-b"] as $site
  | ($site.tenantPrefixOwners["4|10.70.10.0/24"].owner == "b-router-access-hostile")
    and ($site.tenantPrefixOwners["6|fd42:dead:feed:0070:0000:0000:0000:0000/64"].owner == "b-router-access-hostile")
    and ($site.tenantPrefixOwners["6|source:/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"].owner == "b-router-access-hostile")
    and route_has("b-router-access-hostile"; "east-west"; "0.0.0.0/0")
    and route_has("b-router-access-hostile"; "east-west"; "::/0")
' "${output_json}" >/dev/null

echo "PASS policy-source-scope-preserved"
