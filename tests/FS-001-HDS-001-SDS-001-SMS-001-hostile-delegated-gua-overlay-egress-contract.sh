#!/usr/bin/env bash
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-002
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-003
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-004
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-005
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-006
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-CMC-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-CMC-001-002
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-CMC-001-003
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-CMC-001-004
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-CMC-001-005
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-005-SMS-001-CMC-001-006
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"
result_json="${tmp_dir}/result.json"

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "hostile-delegated-gua-overlay-egress: missing network-labs input" else labsPath
  '
)"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
    "${output_json}" >/dev/null
)

OUTPUT_JSON="${output_json}" nix eval --impure --json --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    hostilePrefixSource = "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile";
    siteB = data.control_plane_model.data.espbranch."site-b";
    siteC = data.control_plane_model.data.esp0xdeadbeef."site-c";
    coreNebula = siteB.runtimeTargets."espbranch-site-b-b-router-core-nebula";
    branchHostileAccess = siteB.runtimeTargets."espbranch-site-b-b-router-access-hostile";
    upstreamSelector = siteB.runtimeTargets."espbranch-site-b-b-router-upstream-selector";
    siteCUpstream = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector";
    siteCCore = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-core";
    siteCCoreNebula = siteC.runtimeTargets."esp0xdeadbeef-site-c-c-router-nebula-core";
    coreNebulaIfs = coreNebula.effectiveRuntimeRealization.interfaces;
    branchHostileAccessIfs = branchHostileAccess.effectiveRuntimeRealization.interfaces;
    upstreamIfs = upstreamSelector.effectiveRuntimeRealization.interfaces;
    siteCUpstreamIfs = siteCUpstream.effectiveRuntimeRealization.interfaces;
    siteCCoreNebulaIfs = siteCCoreNebula.effectiveRuntimeRealization.interfaces;

    routes6For = ifs: ifName: (((ifs.${ifName} or { }).routes or { }).ipv6 or [ ]);
    hostileTenantInterfaceNames =
      builtins.filter
        (ifName:
          let iface = branchHostileAccessIfs.${ifName};
          in (iface.sourceKind or null) == "tenant" && (iface.tenant or null) == "hostile")
        (builtins.attrNames branchHostileAccessIfs);
    hostileTenantInterface =
      if hostileTenantInterfaceNames == [ ] then
        { routes.ipv6 = [ ]; backingRef = { }; }
      else
        branchHostileAccessIfs.${builtins.head hostileTenantInterfaceNames};

    nat66DisabledFor =
      target:
      (target.natIntent.families.ipv6 or false) == false
      && (target.natIntent.masqueradeSourcePrefixes6 or [ ]) == [ ];

    branchOverlayDelegatedDefault6 =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.scope or null) == "link"
          && (route.policyOnly or false) == true
          && ((route.intent or { }).kind or null) == "delegated-public-egress"
          && ((route.intent or { }).exitNode or null) == "b-router-access-hostile")
        (routes6For coreNebulaIfs "overlay-east-west");

    branchUpstreamHostilePolicyDefault6 =
      builtins.any
        (route:
          (route.dst or null) == "::/0"
          && (route.via6 or null) == "fd42:dead:feed:1000:0:0:0:4"
          && (route.policyOnly or false) == true
          && ((route.lane or { }).access or null) == "b-router-access-hostile"
          && ((route.intent or { }).kind or null) == "default-reachability")
        (routes6For upstreamIfs "p2p-b-router-core-nebula-b-router-upstream-selector");

    hostileAccessTenantReturn6 =
      builtins.any
        (route:
          (route.sourceFile or null) == hostilePrefixSource
          && !(route ? via6)
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return"
          && ((route.intent or { }).accessNode or null) == "b-router-access-hostile")
        (((hostileTenantInterface.routes or { }).ipv6 or [ ]));

    remoteOverlayReturn6 =
      builtins.any
        (route:
          (route.sourceFile or null) == hostilePrefixSource
          && (route.proto or null) == "overlay"
          && !(route ? via6)
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (routes6For siteCCoreNebulaIfs "overlay-east-west");

    remoteOverlayDoesNotReturnToLocalUpstream6 =
      !(builtins.any
        (route:
          (route.sourceFile or null) == hostilePrefixSource
          && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return")
        (routes6For siteCCoreNebulaIfs "p2p-c-router-nebula-core-c-router-upstream-selector"));

    remoteIngressFirewallSourceScoped6 =
      builtins.any
        (rule:
          (rule.fromInterface or null) == "core-nebula"
          && (rule.toInterface or null) == "pol-client-ew"
          && (rule.action or null) == "accept"
          && builtins.elem hostilePrefixSource (rule.sourceFiles or [ ])
          && ((rule.intent or { }).kind or null) == "runtime-routed-prefix-public-egress")
        (siteCUpstream.forwardingIntent.rules or [ ]);

    remoteIngressFirewallNotDmz6 =
      !builtins.any
        (rule:
          (rule.fromInterface or null) == "core-nebula"
          && (rule.toInterface or null) == "pol-dmz-ew"
          && builtins.elem hostilePrefixSource (rule.sourceFiles or [ ])
          && ((rule.intent or { }).kind or null) == "runtime-routed-prefix-public-egress")
        (siteCUpstream.forwardingIntent.rules or [ ]);

    delegatedGuaNat66Excluded =
      nat66DisabledFor coreNebula
      && nat66DisabledFor siteCCoreNebula
      && nat66DisabledFor siteCCore;
  in
  {
    checks = {
      inherit
        branchOverlayDelegatedDefault6
        branchUpstreamHostilePolicyDefault6
        hostileAccessTenantReturn6
        remoteOverlayReturn6
        remoteOverlayDoesNotReturnToLocalUpstream6
        remoteIngressFirewallSourceScoped6
        remoteIngressFirewallNotDmz6
        delegatedGuaNat66Excluded
        ;
    };
    context = {
      inherit hostilePrefixSource hostileTenantInterfaceNames;
      branchOverlayRoutes6 = routes6For coreNebulaIfs "overlay-east-west";
      branchUpstreamCoreNebulaRoutes6 = routes6For upstreamIfs "p2p-b-router-core-nebula-b-router-upstream-selector";
      hostileTenantRoutes6 = ((hostileTenantInterface.routes or { }).ipv6 or [ ]);
      siteCOverlayRoutes6 = routes6For siteCCoreNebulaIfs "overlay-east-west";
      siteCOverlayUplinkRoutes6 = routes6For siteCCoreNebulaIfs "p2p-c-router-nebula-core-c-router-upstream-selector";
      siteCUpstreamRules = siteCUpstream.forwardingIntent.rules or [ ];
      nat = {
        branchCoreNebula = coreNebula.natIntent;
        siteCCoreNebula = siteCCoreNebula.natIntent;
        siteCCore = siteCCore.natIntent;
      };
    };
  }
' >"${result_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${result_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL hostile-delegated-gua-overlay-egress-contract" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  echo "resolved context:" >&2
  jq '.context' "${result_json}" >&2
  exit 1
fi

echo "PASS hostile-delegated-gua-overlay-egress-contract"
