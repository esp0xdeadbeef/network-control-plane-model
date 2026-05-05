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

nix run "${repo_root}#compile-and-build-control-plane-model" -- "${intent_path}" "${inventory_path}" "${output_json}" >/dev/null

OUTPUT_JSON="${output_json}" nix eval --impure --json --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    siteB = data.control_plane_model.data.espbranch."site-b";
    branchDownstream =
      siteB.runtimeTargets."espbranch-site-b-b-router-downstream-selector".forwardingIntent;
    branchUpstream =
      siteB.runtimeTargets."espbranch-site-b-b-router-upstream-selector".forwardingIntent;
    branchNebulaCore =
      siteB.runtimeTargets."espbranch-site-b-b-router-core-nebula";
    hasRule = rules: from: to:
      builtins.any
        (rule:
          (rule.action or null) == "accept"
          && (rule.fromInterface or null) == from
          && (rule.toInterface or null) == to)
        rules;
    hostileEw =
      siteB.runtimeTargets."espbranch-site-b-b-router-policy"
        .effectiveRuntimeRealization.interfaces
        ."p2p-b-router-policy-b-router-upstream-selector--access-b-router-access-hostile--uplink-east-west".routes;
    hostileIngress =
      siteB.runtimeTargets."espbranch-site-b-b-router-policy"
        .effectiveRuntimeRealization.interfaces
        ."p2p-b-router-downstream-selector-b-router-policy--access-b-router-access-hostile".routes;
    hostileUpstreamCore =
      siteB.runtimeTargets."espbranch-site-b-b-router-upstream-selector"
        .effectiveRuntimeRealization.interfaces
        ."p2p-b-router-core-nebula-b-router-upstream-selector".routes;
    hostileAccessAds =
      siteB.runtimeTargets."espbranch-site-b-b-router-access-hostile".advertisements.ipv6Ra;
    hasDst = routes: destination:
      builtins.any (route: (route.dst or null) == destination) (routes.ipv4 or [ ])
      || builtins.any (route: (route.dst or null) == destination) (routes.ipv6 or [ ]);
    hasRouteVia4 = routes: destination: gateway:
      builtins.any (route: (route.dst or null) == destination && (route.via4 or null) == gateway) (routes.ipv4 or [ ]);
    hasRouteVia6 = routes: destination: gateway:
      builtins.any (route: (route.dst or null) == destination && (route.via6 or null) == gateway) (routes.ipv6 or [ ]);
  in
    {
      hostileEwHasSiteaMgmtV4 = hasDst hostileEw "10.20.10.0/24";
      hostileEwHasSiteaMgmtV6 = hasDst hostileEw "fd42:dead:beef:0010:0000:0000:0000:0000/64";
      hostileIngressDnsUsesEastWestV4 = hasRouteVia4 hostileIngress "10.90.10.1" "10.50.0.17";
      hostileIngressDnsUsesEastWestV6 = hasRouteVia6 hostileIngress "fd42:dead:cafe:10::1" "fd42:dead:feed:1000:0:0:0:11";
      hostileUpstreamCoreDnsUsesNebulaV4 = hasRouteVia4 hostileUpstreamCore "10.90.10.1" "10.50.0.4";
      hostileUpstreamCoreDnsUsesNebulaV6 = hasRouteVia6 hostileUpstreamCore "fd42:dead:cafe:10::1" "fd42:dead:feed:1000:0:0:0:4";
      hostileAccessAdsPresent = hostileAccessAds != [ ];
      hostileAccessSubnet = (builtins.head hostileAccessAds).routerInterface.subnet6 == "fd42:dead:feed:70::/64";
      hostileAccessNoHardcodedPrefix =
        builtins.all
          (entry: !builtins.elem "2a01:4f8:1c17:b337::/64" (entry.prefixes or [ ]))
          hostileAccessAds;
      hostileAccessSecretName =
        (builtins.head hostileAccessAds).externalValidation.delegatedPrefixSecretName
        == "access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile";
      hostileAccessSecretPath =
        (builtins.head hostileAccessAds).externalValidation.delegatedPrefixSecretPath
        == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile";
      branchDownstreamExplicit = branchDownstream.mode == "explicit-selector-forwarding";
      branchDownstreamAccessToPolicy = hasRule branchDownstream.rules "access-branch" "policy-branch";
      branchDownstreamPolicyToAccess = hasRule branchDownstream.rules "policy-branch" "access-branch";
      branchDownstreamHostileToPolicy = hasRule branchDownstream.rules "access-hostile" "policy-hostile";
      branchDownstreamPolicyToHostile = hasRule branchDownstream.rules "policy-hostile" "access-hostile";
      branchDownstreamNoHostileToBranch = !(hasRule branchDownstream.rules "access-hostile" "access-branch");
      branchDownstreamNoBranchToHostile = !(hasRule branchDownstream.rules "access-branch" "access-hostile");
      branchUpstreamExplicit = branchUpstream.mode == "explicit-selector-forwarding";
      branchUpstreamBranchWan = hasRule branchUpstream.rules "policy-branch" "core-isp";
      branchUpstreamWanBranch = hasRule branchUpstream.rules "core-isp" "policy-branch";
      branchUpstreamHostileWan = hasRule branchUpstream.rules "policy-hostile" "core-isp";
      branchUpstreamWanHostile = hasRule branchUpstream.rules "core-isp" "policy-hostile";
      branchUpstreamBranchEw = hasRule branchUpstream.rules "pol-branch-ew" "core-nebula";
      branchUpstreamHostileEw = hasRule branchUpstream.rules "pol-hostile-ew" "core-nebula";
      branchUpstreamCoreNebulaToWan = hasRule branchUpstream.rules "core-nebula" "core-isp";
      branchUpstreamWanToCoreNebula = hasRule branchUpstream.rules "core-isp" "core-nebula";
      branchUpstreamNoHostileToBranch = !(hasRule branchUpstream.rules "policy-hostile" "policy-branch");
      branchUpstreamNoBranchToHostile = !(hasRule branchUpstream.rules "policy-branch" "policy-hostile");
      branchNebulaCoreNoNat = !(branchNebulaCore.natIntent.enabled);
      branchNebulaCoreNoMasquerade = branchNebulaCore.natIntent.masqueradeInterfaces == [ ];
    }
' > "${output_json}.checks"

failed_checks="$(jq -r 'to_entries[] | select(.value != true) | .key' "${output_json}.checks")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL hostile-dns-east-west" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  exit 1
fi

echo "PASS hostile-dns-east-west"
