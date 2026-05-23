#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

archive_json="${work_dir}/archive.json"
output_json="${work_dir}/cpm.json"

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

jq -e '
  def matching($from; $to; $relation; $traffic_type):
    map(select(
      (.action // "") == "accept"
      and (.relationId // "") == $relation
      and (.trafficType // "") == $traffic_type
      and (.fromInterface // "") == $from
      and (.toInterface // "") == $to
    ));
  .control_plane_model.data.esp0xdeadbeef["site-a"].runtimeTargets."esp0xdeadbeef-site-a-s-router-downstream-selector".forwardingIntent.rules as $siteARules
  | .control_plane_model.data.esp0xdeadbeef["site-c"].runtimeTargets."esp0xdeadbeef-site-c-c-router-downstream-selector".forwardingIntent.rules as $siteCRules
  | (($siteARules | matching("access-client"; "access-stream"; "allow-sitea-client-to-streaming-chromecast"; "any") | length) == 1)
    and (($siteARules | matching("access-client"; "access-mgmt"; "allow-sitea-tenants-to-mgmt-dns"; "dns") | length) == 1)
    and (($siteCRules | matching("access-client"; "access-dmz"; "allow-sitec-client-to-dmz-dns"; "dns") | length) == 1)
' "${output_json}" >/dev/null

echo "PASS example-downstream-local-service-forwarding"
