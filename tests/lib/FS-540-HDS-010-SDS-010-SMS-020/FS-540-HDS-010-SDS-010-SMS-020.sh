#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
labs_root="${NETWORK_LABS_PATH:-/home/deadbeef/github/network-labs}"
row="${labs_root}/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-020"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
	echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: $*" >&2
	exit 1
}

for source in intent.nix inventory-nixos.nix inventory-clab.nix; do
	[[ -f "${row}/${source}" ]] || fail "missing controlled row source ${row}/${source}"
done

taxonomy="$({
	REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
    let
      flake = builtins.getFlake (toString (builtins.getEnv "REPO_ROOT"));
      lib = flake.inputs.nixpkgs.lib;
      helpers = import (builtins.getEnv "REPO_ROOT" + "/lib/contract.nix") { inherit lib; };
      common = {
        attrsOrEmpty = value: if builtins.isAttrs value then value else { };
        failInventory = path: message: builtins.throw "${path}: ${message}";
      };
      taxonomyModule = import (builtins.getEnv "REPO_ROOT" + "/src/cpm/Unit/runtime-targets/interfaces/taxonomy.nix") {
        inherit helpers common;
      };
      evaluate = sourceKind: nodeRole:
        (taxonomyModule.taxonomyFor {
          ifacePath = "seeded.${sourceKind}.${nodeRole}";
          ifName = "if0";
          inherit sourceKind nodeRole;
          backingRef = { name = "seeded"; };
          targetDef = null;
          portBinding = null;
          fabricLinkBinding = null;
          overlayProvisioning = { };
        }).dnsResolver;
    in [
      (evaluate "tenant" "access")
      (evaluate "tenant" "core")
      (evaluate "wan" "core")
      (evaluate "p2p" "upstream-selector")
    ]
  '
} 2>/dev/null)" || fail "cannot evaluate neutral interface taxonomy"

jq -e 'all(.[];
  . == {
    authoritySource: null,
    resolver4: null,
    resolver6: null,
    resolverSource: "none"
  }
)' <<<"${taxonomy}" >/dev/null || fail "interface role/sourceKind still invents DNS authority"

echo "PASS taxonomy does not infer DNS authority from tenant, access, core, WAN, or P2P identity"

compile_row() {
	local inventory="$1"
	local output="$2"

	nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
		"${row}/intent.nix" \
		"${row}/${inventory}" \
		"${output}" >/dev/null
}

nixos_output="${tmp_dir}/nixos.json"
clab_output="${tmp_dir}/clab.json"
compile_row inventory-nixos.nix "${nixos_output}"
compile_row inventory-clab.nix "${clab_output}"

assert_contract() {
	local substrate="$1"
	local output="$2"

	jq -e '
    .control_plane_model.data."mini-smt"."FS-540-HDS-010-SDS-010-SMS-020".runtimeTargets as $targets
    | $targets."mini-smt-FS-540-HDS-010-SDS-010-SMS-020-access-dns" as $access
    | $targets."mini-smt-FS-540-HDS-010-SDS-010-SMS-020-resolver-node" as $core
    | $access.services.dns as $accessDns
    | $core.services.dns as $coreDns
    | $access.effectiveRuntimeRealization.interfaces."tenant-client".dnsResolver as $resolver
    | ($targets | [to_entries[] | .value.effectiveRuntimeRealization.interfaces | to_entries[] | {
        target: .key,
        sourceKind: .value.sourceKind,
        dnsResolver: .value.dnsResolver
      }]) as $interfaces
    | ($accessDns.upstreamResolvers | map(select(.kind == "named-core-resolver"))) as $upstreams
    | ($coreDns.serviceEndpointBindings | map(select(.service == "core-dns"))) as $endpointBindings
    | ($accessDns.reproducibilityWarnings + $coreDns.reproducibilityWarnings) as $warnings
    | ($resolver == {
        authoritySource: "named-dns-binding",
        coreServiceName: "core-dns",
        relationId: "FS-540-HDS-010-SDS-010-SMS-020__mini-access-dns-to-core-dns",
        requesterRelationIds: ["FS-540-HDS-010-SDS-010-SMS-020__mini-client-to-access-dns"],
        requesterServiceName: "access-dns",
        resolver4: "127.0.0.1",
        resolver6: "::1",
        resolverSource: "local-recursive"
      })
    and ([$interfaces[] | select(.dnsResolver.resolverSource != "none")] | length) == 1
    and ([$interfaces[] | select(.dnsResolver.resolverSource == "none") | select(
      .dnsResolver.resolver4 != null
      or .dnsResolver.resolver6 != null
      or .dnsResolver.authoritySource != null
    )] | length) == 0
    and ($accessDns.recursionMode == "forwarding")
    and (($accessDns.forwarders // []) == [])
    and (($upstreams | length) == 1)
    and ($upstreams[0].service == "core-dns")
    and ($upstreams[0].node == "resolver-node")
    and ($upstreams[0].addresses == $coreDns.listen)
    and (($upstreams[0].addresses | length) == 2)
    and ($upstreams[0].endpointAuthority.relationId == "FS-540-HDS-010-SDS-010-SMS-020__mini-access-dns-to-core-dns")
    and ($upstreams[0].endpointAuthority.terminalAttachmentId == "link::mini-smt.FS-540-HDS-010-SDS-010-SMS-020::p2p-resolver-node-upstream-selector")
    and ($coreDns.recursionMode == "iterative")
    and ($coreDns.forwarders == [])
    and ($coreDns.outgoingInterfaces == [])
    and ($coreDns.egress.uplinks == ["testnet-vlan4"])
    and (($endpointBindings | length) == 1)
    and ($endpointBindings[0].addresses == $coreDns.listen)
    and ($endpointBindings[0].terminalAttachmentId == $upstreams[0].endpointAuthority.terminalAttachmentId)
    and ($core.runtimeOriginEgress.enabled == true)
    and ($core.runtimeOriginEgress.policyRoutingRequired == true)
    and ($core.runtimeOriginEgress.uplinks == ["testnet-vlan4"])
    and ($core.runtimeOriginEgress.policyRouting.source == "control-plane-model")
    and ($warnings == [])
  ' "${output}" >/dev/null || fail "${substrate} CPM output violates the named-core DNS authority contract"

	echo "PASS ${substrate} CPM output carries the complete dual-stack named-core DNS authority without fallback"
}

assert_contract nixos "${nixos_output}"
assert_contract clab "${clab_output}"

canonical_contract() {
	jq -Sc '
    .control_plane_model.data."mini-smt"."FS-540-HDS-010-SDS-010-SMS-020".runtimeTargets as $targets
    | {
        accessDns: $targets."mini-smt-FS-540-HDS-010-SDS-010-SMS-020-access-dns".services.dns,
        requesterResolver: $targets."mini-smt-FS-540-HDS-010-SDS-010-SMS-020-access-dns".effectiveRuntimeRealization.interfaces."tenant-client".dnsResolver,
        coreDns: $targets."mini-smt-FS-540-HDS-010-SDS-010-SMS-020-resolver-node".services.dns,
        coreRuntimeOrigin: $targets."mini-smt-FS-540-HDS-010-SDS-010-SMS-020-resolver-node".runtimeOriginEgress
      }
  ' "$1"
}

nixos_contract="$(canonical_contract "${nixos_output}")"
clab_contract="$(canonical_contract "${clab_output}")"
[[ "${nixos_contract}" == "${clab_contract}" ]] || fail "NixOS and CLAB received divergent CPM DNS authority"

echo "PASS NixOS and CLAB receive one identical platform-neutral DNS authority contract"
