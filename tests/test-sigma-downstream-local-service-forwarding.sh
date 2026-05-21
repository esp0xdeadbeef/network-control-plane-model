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

cat >"${inventory_nix}" <<EOF
import ${lab_dir}/getResolvedInventory.nix { renderer = "nixos"; }
EOF

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${lab_dir}/intent.nix" \
  "${inventory_nix}" \
  "${output_json}" >/dev/null

jq -e '
  def expect($actual; $expected):
    if $actual == $expected then true
    else error("expected " + ($expected | @json) + " got " + ($actual | @json))
    end;
  def matching($from; $to; $relation):
    map(select(
      (.action // "") == "accept"
      and (.relationId // "") == $relation
      and (.trafficType // "") == "dns"
      and (.fromInterface // "") == $from
      and (.toInterface // "") == $to
    ));

  .control_plane_model.data.esp.hetz.runtimeTargets."esp-hetz-router-downstream".forwardingIntent.rules as $rules
  | expect(($rules | matching("access-client"; "access-dmz"; "allow-hetz-client-to-dmz-dns") | length); 1)
' "${output_json}" >/dev/null

echo "PASS sigma-downstream-local-service-forwarding"
