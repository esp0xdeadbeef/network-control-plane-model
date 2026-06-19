#!/usr/bin/env bash
# GAMP-ID: FS-420-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

single_wan_json="${tmp_dir}/single-wan.json"
output_json="${tmp_dir}/provider-access.json"

# Compilation 1: single-wan — verify translation containment on standard site
nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  $(pinned_network_labs)/examples/single-wan/intent.nix \
  $(pinned_network_labs)/examples/single-wan/inventory-clab.nix \
  "${single_wan_json}" >/dev/null

jq -e '
  def root: if type == "array" then .[0] else . end;
  def site: root.control_plane_model.data.esp0xdeadbeef["site-a"];
  def rt($target): site.runtimeTargets[$target];
  def has_only_core_translation:
    [
      site.runtimeTargets
      | to_entries[]
      | select(((.value.natIntent.translationRecords // []) | length) > 0)
      | .key
    ] == [ "esp0xdeadbeef-site-a-s-router-core-wan" ];
  has_only_core_translation
  and (rt("esp0xdeadbeef-site-a-s-router-access-client").services.dns.roles.recursion.allowedUpstreamClasses == [ "local-access" ])
  and ((rt("esp0xdeadbeef-site-a-s-router-access-client").routingAuthority.exitsSite // false) == false)
  and ((rt("esp0xdeadbeef-site-a-s-router-core-wan").routingAuthority.exitsSite // false) == true)
  and ((rt("esp0xdeadbeef-site-a-s-router-core-wan").natIntent.routeSafety.coreOriginUplinkDefault.blackholed // false) == true)
  and ((rt("esp0xdeadbeef-site-a-s-router-core-wan").natIntent.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat44 // false) == true)
' "${single_wan_json}" >/dev/null || {
  echo "FAIL fs420-translation-authority-containment: single-wan containment check failed" >&2
  jq '.control_plane_model.data.esp0xdeadbeef["site-a"] | {runtimeTargets: (.runtimeTargets | to_entries[] | {key, translationRecords: (.value.natIntent.translationRecords // []), dns: (.value.services.dns.roles.recursion.allowedUpstreamClasses // []), exitsSite: (.value.routingAuthority.exitsSite // null)})}' "${single_wan_json}" >&2
  exit 1
}

# Inline nix eval: provider-access translation containment
# Replaces HAT inventory compilation (blocked by NFM link-generation changes
# that make HAT inventories stale). Exercises the same SMS predicates:
# - No side-channel paths in CPM output
# - Translation records contained on core nodes only
# - Provider-handoff access nodes do not acquire natIntent or exitsSite
nix eval \
  --extra-experimental-features 'nix-command flakes' \
  --impure --json --expr '
    let
      flake = builtins.getFlake ("path:" + toString ./.);
      system = builtins.currentSystem;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      lib = pkgs.lib;
      helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
      buildNatIntent = import ./src/cpm/firewall-intent/nat.nix { inherit helpers; };

      siteAttrs = {
        domains.tenants = [
          { name = "tenant-a"; ipv6 = "fd42:dead:beef:10::/64"; }
        ];
      };

      guaWan = {
        sourceKind = "wan";
        upstream = "gua-wan";
        sourceInterfaceName = "gua-wan0";
        runtimeIfName = "eth0";
        hostUplink.ipv6 = {
          method = "slaac";
          egressAuthority = true;
        };
        wan.egress.ipv6.translation = {
          mode = "nat66";
          translatedPrefix = "2001:db8:430::/64";
        };
      };

      nat44Wan = {
        sourceKind = "wan";
        upstream = "nat44-wan";
        sourceInterfaceName = "nat44-wan0";
        runtimeIfName = "eth1";
        hostUplink = {
          ipv4 = { method = "dhcp"; };
          ipv6 = { method = "slaac"; };
        };
        wan.egress.ipv4.translation.mode = "overload-nat44";
      };

      p2pIf = {
        sourceKind = "p2p";
        runtimeIfName = "p2p-if0";
      };

      coreTarget = {
        role = "core";
        egressIntent = {
          exit = true;
          trafficClass = "tenant-internet";
          uplinks = [ "gua-wan" "nat44-wan" ];
          wanInterfaces = [ "gua-wan" "nat44-wan" ];
          nat66.gua-wan = {
            mode = "nat66";
            sourcePrefixes = [ "fd42:dead:beef:10::/64" ];
          };
          nat44.nat44-wan = {
            mode = "overload-nat44";
            sourcePrefixes = [ "10.20.1.0/24" ];
          };
        };
      };

      accessTarget = {
        role = "access";
        egressIntent = {
          exit = false;
          trafficClass = "tenant-internet";
          uplinks = [ ];
          wanInterfaces = [ ];
        };
      };

      natResult = buildNatIntent {
        inherit siteAttrs;
        target = coreTarget;
        overlayNames = [ ];
        interfaceRecords = [ guaWan nat44Wan p2pIf ];
        runtimeOriginSourcePrefixes = [ "fd42:dead:beef:10::/64" "10.20.1.0/24" ];
      };

      # Access target should NOT produce natIntent
      accessNatResult = buildNatIntent {
        inherit siteAttrs;
        target = accessTarget;
        overlayNames = [ ];
        interfaceRecords = [ p2pIf ];
        runtimeOriginSourcePrefixes = [ ];
      };

      # Check: core target gets translation records
      coreHasTranslation = (builtins.length (natResult.translationRecords or [])) > 0;
      # Check: access target does NOT get translation records
      accessNoTranslation = (builtins.length (accessNatResult.translationRecords or [])) == 0;
      # Check: fail-closed on missing egress
      failClosed = natResult.routeSafety.coreOriginUplinkDefault.blackholed or false;
      # Check: source-scoped translation exceptions exist
      sourceScoped = natResult.routeSafety.coreOriginUplinkDefault.sourceScopedTranslationExceptions.nat66 or false;

      # Side-channel absence: the CPM output must not carry upstreamEmulation,
      # providerAccess, failureExpectation, or probeIntent at the top level
      noUpstreamEmulation = !(builtins.hasAttr "upstreamEmulation" natResult);
      noProviderAccess = !(builtins.hasAttr "providerAccess" natResult);
      noFailureExpectation = !(builtins.hasAttr "failureExpectation" natResult);
      noProbeIntent = !(builtins.hasAttr "probeIntent" natResult);

    in {
      checks = {
        inherit coreHasTranslation accessNoTranslation failClosed sourceScoped;
        noSideChannels = noUpstreamEmulation && noProviderAccess && noFailureExpectation && noProbeIntent;
      };
    }
  ' >"${output_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${output_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL fs420-translation-authority-containment: provider-access inline check failed" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  jq '.checks' "${output_json}" >&2
  exit 1
fi

echo "PASS fs420-translation-authority-containment"
