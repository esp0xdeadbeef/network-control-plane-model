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

intent_path="${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix"
inventory_path="${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix"

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
        sitebNebulaCore =
          out.control_plane_model.data.espbranch."site-b".runtimeTargets."espbranch-site-b-b-router-core-nebula".effectiveRuntimeRealization.interfaces;
        siteaPolicy =
          out.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets."esp0xdeadbeef-site-a-s-router-policy".effectiveRuntimeRealization.interfaces;
        sitecPolicy =
          out.control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-policy".effectiveRuntimeRealization.interfaces;
        sitecCore =
          out.control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-core".effectiveRuntimeRealization.interfaces;
        sitebPolicy =
          out.control_plane_model.data.espbranch."site-b".runtimeTargets."espbranch-site-b-b-router-policy".effectiveRuntimeRealization.interfaces;
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
        siteaUpstreamMgmtWanA =
          siteaUpstream."p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-mgmt--uplink-isp-a".routes;
        siteaUpstreamMgmtWanB =
          siteaUpstream."p2p-s-router-policy-only-s-router-upstream-selector--access-s-router-access-mgmt--uplink-isp-b".routes;
        siteaUpstreamEastWestCore =
          siteaUpstream."p2p-s-router-core-nebula-s-router-upstream-selector".routes;
        siteaPolicyAdmin =
          siteaPolicy."p2p-s-router-downstream-selector-s-router-policy-only--access-s-router-access-admin".routes;
        sitecClient =
          sitecPolicy."p2p-c-router-downstream-selector-c-router-policy--access-c-router-access-client".routes;
        sitecDmz =
          sitecPolicy."p2p-c-router-downstream-selector-c-router-policy--access-c-router-access-dmz".routes;
        sitecCoreUpstream =
          sitecCore."p2p-c-router-core-c-router-upstream-selector".routes;
        sitebBranch =
          sitebPolicy."p2p-b-router-downstream-selector-b-router-policy--access-b-router-access-branch".routes;
        sitebHostile =
          sitebPolicy."p2p-b-router-downstream-selector-b-router-policy--access-b-router-access-hostile".routes;
        sitebHostileEastWest =
          sitebPolicy."p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west".routes;
        sitebNebulaCoreUpstream =
          sitebNebulaCore."p2p-b-router-core-nebula-b-router-upstream-selector".routes;
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
          mgmtWanLaneKeepsMgmtPrefixV4 =
            hasRoute (siteaUpstreamMgmtWanA.ipv4 or [ ]) "10.20.10.0/24" "10.10.0.50";
          mgmtWanLaneKeepsMgmtPrefixV6 =
            hasRoute (siteaUpstreamMgmtWanA.ipv6 or [ ]) "fd42:dead:beef:10::/64" "fd42:dead:beef:1000:0:0:0:32";
          mgmtWanBLaneKeepsMgmtPrefixV4 =
            hasRoute (siteaUpstreamMgmtWanB.ipv4 or [ ]) "10.20.10.0/24" "10.10.0.52";
          mgmtWanBLaneKeepsMgmtPrefixV6 =
            hasRoute (siteaUpstreamMgmtWanB.ipv6 or [ ]) "fd42:dead:beef:10::/64" "fd42:dead:beef:1000:0:0:0:34";
          eastWestIngressDoesNotCloneSiteaMgmtDnsPrefixV4 =
            !(hasRoute (siteaUpstreamEastWestCore.ipv4 or [ ]) "10.20.10.0/24" "10.10.0.30");
          eastWestIngressDoesNotCloneSiteaMgmtDnsPrefixV6 =
            !(hasRoute (siteaUpstreamEastWestCore.ipv6 or [ ]) "fd42:dead:beef:10::/64" "fd42:dead:beef:1000:0:0:0:1e");
          eastWestIngressDoesNotSendSiteaMgmtDnsToWanA =
            !(hasRoute (siteaUpstreamEastWestCore.ipv4 or [ ]) "10.20.10.0/24" "10.10.0.12");
          eastWestIngressDoesNotSendSiteaMgmtDnsToWanB =
            !(hasRoute (siteaUpstreamEastWestCore.ipv4 or [ ]) "10.20.10.0/24" "10.10.0.14");
          adminDnsDoesNotCloneMgmtPrefixV4 =
            !(hasRoute (siteaPolicyAdmin.ipv4 or [ ]) "10.20.10.0/24" "10.10.0.26");
          adminDnsDoesNotOverrideMgmtPrefixV4 =
            !(hasRoute (siteaPolicyAdmin.ipv4 or [ ]) "10.20.10.1" "10.10.0.31");
          adminDnsDoesNotCloneMgmtPrefixV6 =
            !(hasRoute (siteaPolicyAdmin.ipv6 or [ ]) "fd42:dead:beef:10::/64" "fd42:dead:beef:1000:0:0:0:1a");
          adminDnsDoesNotOverrideMgmtPrefixV6 =
            !(hasRoute (siteaPolicyAdmin.ipv6 or [ ]) "fd42:dead:beef:10::1" "fd42:dead:beef:1000:0:0:0:21");
          sitecClientDoesNotCloneDmzDnsPrefixV4 =
            !(hasRoute (sitecClient.ipv4 or [ ]) "10.90.10.0/24" "10.80.0.8");
          sitecDmzKeepsOwnDnsPrefixV4 =
            hasRoute (sitecDmz.ipv4 or [ ]) "10.90.10.0/24" "10.80.0.8";
          sitecCoreKeepsInternalDmzDnsPrefixV4 =
            hasRoute (sitecCoreUpstream.ipv4 or [ ]) "10.90.10.0/24" "10.80.0.5";
          sitecCoreDoesNotOverrideDmzDnsPrefixV4 =
            !(hasRoute (sitecCoreUpstream.ipv4 or [ ]) "10.90.10.0/24" "172.31.254.1");
          sitecCoreDoesNotOverrideDmzDnsAddressV4 =
            !(hasRoute (sitecCoreUpstream.ipv4 or [ ]) "10.90.10.1" "172.31.254.1");
          sitebBranchDnsUsesSiteaEastWestV4 =
            hasRoute (sitebBranch.ipv4 or [ ]) "10.20.10.1" "10.50.0.13";
          sitebBranchDnsUsesSiteaEastWestV6 =
            hasRoute (sitebBranch.ipv6 or [ ]) "fd42:dead:beef:10::1" "fd42:dead:feed:1000:0:0:0:d";
          sitebHostileDoesNotLearnSiteaMgmtDnsV4 =
            !(hasRoute (sitebHostile.ipv4 or [ ]) "10.20.10.1" "10.50.0.17");
          sitebHostileDoesNotLearnSiteaMgmtDnsV6 =
            !(hasRoute (sitebHostile.ipv6 or [ ]) "fd42:dead:beef:10::1" "fd42:dead:feed:1000:0:0:0:11");
          sitebHostileEastWestReturnUsesDownstreamV4 =
            hasRoute (sitebHostileEastWest.ipv4 or [ ]) "10.70.10.0/24" "10.50.0.10";
          sitebHostileEastWestReturnDoesNotUseWanV4 =
            !(hasRoute (sitebHostileEastWest.ipv4 or [ ]) "10.70.10.0/24" "10.50.0.19");
          sitebHostileEastWestReturnUsesDownstreamV6 =
            hasRoute (sitebHostileEastWest.ipv6 or [ ]) "fd42:dead:feed:70::/64" "fd42:dead:feed:1000:0:0:0:a";
          sitebHostileEastWestReturnDoesNotUseWanV6 =
            !(hasRoute (sitebHostileEastWest.ipv6 or [ ]) "fd42:dead:feed:70::/64" "fd42:dead:feed:1000:0:0:0:13");
          sitebBranchDnsDoesNotUseWanV6 =
            !(hasRoute (sitebBranch.ipv6 or [ ]) "fd42:dead:beef:10::1" "fd42:dead:feed:1000:0:0:0:f");
          sitebNebulaCoreDoesNotOverrideSitecDnsV4 =
            !(hasRoute (sitebNebulaCoreUpstream.ipv4 or [ ]) "10.90.10.1" "10.50.0.5");
          sitebNebulaCoreDoesNotOverrideSitecDnsV6 =
            !(hasRoute (sitebNebulaCoreUpstream.ipv6 or [ ]) "fd42:dead:cafe:10::1" "fd42:dead:feed:1000:0:0:0:5");
          nebulaCoreDoesNotNat = !(siteaNebulaCore.natIntent.enabled);
          nebulaCoreHasNoMasqueradeInterfaces = siteaNebulaCore.natIntent.masqueradeInterfaces == [ ];
        };
        context = {
          inherit siteaUpstreamClient siteaUpstreamMgmt siteaUpstreamMgmtWanA siteaUpstreamMgmtWanB siteaUpstreamEastWestCore siteaPolicyAdmin sitebBranch sitebHostile sitebHostileEastWest sitebNebulaCoreUpstream sitecClient sitecDmz sitecCoreUpstream;
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
