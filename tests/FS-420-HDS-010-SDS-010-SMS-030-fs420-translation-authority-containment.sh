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
provider_access_json="${tmp_dir}/provider-access.json"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  $(pinned_network_labs)/examples/single-wan/intent.nix \
  $(pinned_network_labs)/examples/single-wan/inventory-clab.nix \
  "${single_wan_json}" >/dev/null

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  $(pinned_hat_dir)/intent.nix \
  $(pinned_hat_dir)/inventory-nixos.nix \
  "${provider_access_json}" >/dev/null

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

jq -e '
  def root: if type == "array" then .[0] else . end;
  def side_channel_path:
    root.control_plane_model
    | paths
    | select(
      .[-1] == "upstreamEmulation"
      or .[-1] == "providerAccess"
      or .[-1] == "failureExpectation"
      or .[-1] == "probeIntent"
    );
  def site: root.control_plane_model.data.esp0xdeadbeef["site-a"];
  def rt($target): site.runtimeTargets[$target];
  ([side_channel_path] == [])
  and any(site.runtimeTargets | to_entries[]; ((.value.natIntent.translationRecords // []) | length) > 0)
  and (rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a").natIntent? == null)
  and (rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b").natIntent? == null)
  and ((rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-a").routingAuthority.exitsSite // null) == null)
  and ((rt("esp0xdeadbeef-site-a-nixos-provider-handoff-access-b").routingAuthority.exitsSite // null) == null)
' "${provider_access_json}" >/dev/null || {
  echo "FAIL fs420-translation-authority-containment: provider-access containment check failed" >&2
  jq '.control_plane_model.data.esp0xdeadbeef["site-a"] | {runtimeTargets: (.runtimeTargets | to_entries[] | {key, hasNatIntent: (.value.natIntent != null), translationRecords: (.value.natIntent.translationRecords // []), exitsSite: (.value.routingAuthority.exitsSite // null)})}' "${provider_access_json}" >&2
  exit 1
}

echo "PASS fs420-translation-authority-containment"
