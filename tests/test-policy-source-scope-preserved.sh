#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

archive_json="$(mktemp)"
work_dir="$(mktemp -d)"
trap 'rm -f "${archive_json}"; rm -rf "${work_dir}"' EXIT

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

lab_dir="${labs_path}/labs/lab-s-sigma/s-router-test-three-site"
inventory_nix="${work_dir}/inventory.nix"
output_json="${work_dir}/cpm.json"
gron_txt="${work_dir}/cpm.gron"

cat >"${inventory_nix}" <<EOF
import ${lab_dir}/getResolvedInventory.nix { renderer = "nixos"; }
EOF

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${lab_dir}/intent.nix" \
  "${inventory_nix}" \
  "${output_json}" >/dev/null

gron "${output_json}" >"${gron_txt}"

require_gron() {
  local pattern="$1"
  if ! rg -q --fixed-strings "${pattern}" "${gron_txt}"; then
    echo "FAIL policy-source-scope-preserved: missing gron line: ${pattern}" >&2
    exit 1
  fi
}

require_gron 'json.control_plane_model.data.esp.nixos.tenantPrefixOwners["4|10.20.70.0/24"].owner = "nixos-router-access-hostile";'
require_gron 'json.control_plane_model.data.esp.nixos.tenantPrefixOwners["6|source:/run/secrets/access-node-ipv6-prefix-esp-nixos-router-access-hostile"].owner = "nixos-router-access-hostile";'
require_gron 'json.control_plane_model.data.esp.nixos.runtimeTargets["esp-nixos-router-policy"].effectiveRuntimeRealization.interfaces["p2p-nixos-router-policy-nixos-router-upstream--access-nixos-router-access-hostile--uplink-east-west"].routes.ipv4[0].lane.access = "nixos-router-access-hostile";'
require_gron 'json.control_plane_model.data.esp.nixos.runtimeTargets["esp-nixos-router-policy"].effectiveRuntimeRealization.interfaces["p2p-nixos-router-policy-nixos-router-upstream--access-nixos-router-access-hostile--uplink-east-west"].routes.ipv4[0].lane.uplink = "east-west";'

jq -e '
  def route_has($access; $uplink; $dst):
    [.control_plane_model.data.esp.nixos.runtimeTargets."esp-nixos-router-policy"
      .effectiveRuntimeRealization.interfaces[]
      .routes.ipv4[]?, .control_plane_model.data.esp.nixos.runtimeTargets."esp-nixos-router-policy"
      .effectiveRuntimeRealization.interfaces[]
      .routes.ipv6[]?
      | select(
          (.policyOnly // false) == true
          and (.reason // "") == "policy-derived-default"
          and (.lane.access // "") == $access
          and (.lane.uplink // "") == $uplink
          and (.dst // "") == $dst
        )] | length > 0;
  .control_plane_model.data.esp.nixos as $site
  | ($site.tenantPrefixOwners["4|10.20.70.0/24"].owner == "nixos-router-access-hostile")
    and ($site.tenantPrefixOwners["6|fd42:dead:beef:0070:0000:0000:0000:0000/64"].owner == "nixos-router-access-hostile")
    and ($site.tenantPrefixOwners["6|source:/run/secrets/access-node-ipv6-prefix-esp-nixos-router-access-hostile"].owner == "nixos-router-access-hostile")
    and route_has("nixos-router-access-hostile"; "east-west"; "0.0.0.0/0")
    and route_has("nixos-router-access-hostile"; "east-west"; "::/0")
' "${output_json}" >/dev/null || {
  cat >&2 <<'EOF'
FAIL policy-source-scope-preserved

CPM must preserve the NFM source-scoped policy-routing contract. If this data is
present, broad renderer rules such as "from all iif downstr-client lookup ..."
are renderer materialization bugs, not permission for CPM to invent new policy.
EOF
  exit 1
}

echo "PASS policy-source-scope-preserved"
