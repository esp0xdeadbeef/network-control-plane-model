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

nix run "${repo_root}#compile-and-build-control-plane-model" -- "${intent_path}" "${inventory_path}" "${output_json}" >/dev/null

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
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
    hasDst hostileEw "10.20.10.0/24"
    && hasDst hostileEw "fd42:dead:beef:0010:0000:0000:0000:0000/64"
    && hasRouteVia4 hostileIngress "10.90.10.1" "10.50.0.17"
    && hasRouteVia6 hostileIngress "fd42:dead:cafe:10::1" "fd42:dead:feed:1000:0:0:0:11"
    && hasRouteVia4 hostileUpstreamCore "10.90.10.1" "10.50.0.4"
    && hasRouteVia6 hostileUpstreamCore "fd42:dead:cafe:10::1" "fd42:dead:feed:1000:0:0:0:4"
    && (hostileAccessAds != [ ])
    && (builtins.head hostileAccessAds).routerInterface.subnet6 == "fd42:dead:feed:70::/64"
    && builtins.all
      (entry: !builtins.elem "2a01:4f8:1c17:b337::/64" (entry.prefixes or [ ]))
      hostileAccessAds
    && (builtins.head hostileAccessAds).externalValidation.delegatedPrefixSecretName
      == "access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
    && (builtins.head hostileAccessAds).externalValidation.delegatedPrefixSecretPath
      == "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile"
    && branchDownstream.mode == "explicit-selector-forwarding"
    && hasRule branchDownstream.rules "access-branch" "policy-branch"
    && hasRule branchDownstream.rules "policy-branch" "access-branch"
    && hasRule branchDownstream.rules "access-hostile" "policy-hostile"
    && hasRule branchDownstream.rules "policy-hostile" "access-hostile"
    && !(hasRule branchDownstream.rules "access-hostile" "access-branch")
    && !(hasRule branchDownstream.rules "access-branch" "access-hostile")
    && branchUpstream.mode == "explicit-selector-forwarding"
    && hasRule branchUpstream.rules "policy-branch" "core-isp"
    && hasRule branchUpstream.rules "core-isp" "policy-branch"
    && hasRule branchUpstream.rules "policy-hostile" "core-isp"
    && hasRule branchUpstream.rules "core-isp" "policy-hostile"
    && hasRule branchUpstream.rules "pol-branch-ew" "core-nebula"
    && hasRule branchUpstream.rules "pol-hostile-ew" "core-nebula"
    && hasRule branchUpstream.rules "core-nebula" "core-isp"
    && hasRule branchUpstream.rules "core-isp" "core-nebula"
    && !(hasRule branchUpstream.rules "policy-hostile" "policy-branch")
    && !(hasRule branchUpstream.rules "policy-branch" "policy-hostile")
    && !(branchNebulaCore.natIntent.enabled)
    && branchNebulaCore.natIntent.masqueradeInterfaces == [ ]
' | grep -qx true

echo "PASS hostile-dns-east-west"
