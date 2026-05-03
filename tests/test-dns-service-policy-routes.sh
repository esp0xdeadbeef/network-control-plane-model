#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

archive_json="$(mktemp)"
output_json="$(mktemp)"
trap 'rm -f "'"${archive_json}"'" "'"${output_json}"'"' EXIT

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then
        throw "tests: missing archived network-labs input path"
      else
        labsPath
  '
)"

intent_path="${labs_path}/examples/s-router-test-three-site/intent.nix"
inventory_path="${labs_path}/examples/s-router-test-three-site/inventory-nixos.nix"

REPO_ROOT="${repo_root}" \
INTENT_PATH="${intent_path}" \
INVENTORY_PATH="${inventory_path}" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
        out = flake.lib.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
        };
        siteaUpstream =
          out.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets."esp0xdeadbeef-site-a-s-router-upstream-selector".effectiveRuntimeRealization.interfaces;
        siteaNebulaCore =
          out.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets."esp0xdeadbeef-site-a-s-router-core-nebula";
        sitecPolicy =
          out.control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-policy".effectiveRuntimeRealization.interfaces;
        hasRoute = routes: destination: gateway:
          builtins.any
            (route:
              (route.dst or null) == destination
              && (
                (route.via4 or null) == gateway
                || (route.via6 or null) == gateway
              ))
            routes;
        siteaUpstreamClient =
          siteaUpstream."p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-client--uplink-east-west".routes;
        siteaUpstreamMgmt =
          siteaUpstream."p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-mgmt--uplink-east-west".routes;
        sitecClient =
          sitecPolicy."p2p-c-router-downstream-selector-c-router-policy--access-c-router-access-client".routes;
        sitecDmz =
          sitecPolicy."p2p-c-router-downstream-selector-c-router-policy--access-c-router-access-dmz".routes;
      in {
        checks = {
          clientLaneDoesNotLearnMgmtDnsV4 =
            !(hasRoute (siteaUpstreamClient.ipv4 or [ ]) "10.20.10.0/24" "10.10.0.48");
          clientLaneDoesNotLearnMgmtDnsV6 =
            !(hasRoute (siteaUpstreamClient.ipv6 or [ ]) "fd42:dead:beef:0010:0000:0000:0000:0000/64" "fd42:dead:beef:1000:0:0:0:30");
          mgmtLaneLearnsMgmtDnsV4 =
            hasRoute (siteaUpstreamMgmt.ipv4 or [ ]) "10.20.10.0/24" "10.10.0.48";
          mgmtLaneLearnsMgmtDnsV6 =
            hasRoute (siteaUpstreamMgmt.ipv6 or [ ]) "fd42:dead:beef:0010:0000:0000:0000:0000/64" "fd42:dead:beef:1000:0:0:0:30";
          sitecClientLearnsDmzDnsV4 =
            hasRoute (sitecClient.ipv4 or [ ]) "10.90.10.0/24" "10.80.0.8";
          sitecDmzKeepsOwnDnsPrefixV4 =
            hasRoute (sitecDmz.ipv4 or [ ]) "10.90.10.0/24" "10.80.0.8";
          nebulaCoreDoesNotNat = !(siteaNebulaCore.natIntent.enabled);
          nebulaCoreHasNoMasqueradeInterfaces = siteaNebulaCore.natIntent.masqueradeInterfaces == [ ];
        };
        context = {
          inherit siteaUpstreamClient siteaUpstreamMgmt sitecClient sitecDmz;
          natIntent = siteaNebulaCore.natIntent;
          sitecPolicyInterfaces = builtins.attrNames sitecPolicy;
        };
      }
    ' > "${output_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${output_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL dns-service-policy-routes" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  echo "resolved context:" >&2
  jq '.context' "${output_json}" >&2
  exit 1
fi

echo "PASS dns-service-policy-routes"
