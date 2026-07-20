#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

labs_path="${NETWORK_LABS_ROOT:-}"
if [[ -z "${labs_path}" && -d "${repo_root}/../network-labs/current-lab" ]]; then
  labs_path="$(cd "${repo_root}/../network-labs" && pwd)"
fi

if [[ -z "${labs_path}" ]]; then
  archive_json="${tmp_dir}/archive.json"
  nix flake archive --json "path:${repo_root}" >"${archive_json}"
  labs_path="$(
    ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
      let
        archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
        labs = archived.inputs."network-labs" or null;
        labsPath = if labs == null then null else labs.path or null;
      in
        if labsPath == null then throw "FS-540 active-lab DNS service-origin egress: missing network-labs input path" else labsPath
    '
  )"
fi

selection_trace="$(
  LABS_PATH="${labs_path}" nix eval --impure --raw --expr '
    let current = import ((builtins.getEnv "LABS_PATH") + "/current-lab");
    in current.selection.traceId or ""
  '
)"
if [[ "${selection_trace}" != "FS-540-HDS-010-SDS-010" ]]; then
  echo "FAIL FS-540 active-lab DNS service-origin egress: current-lab must be selected to SIT FS-540-HDS-010-SDS-010, got ${selection_trace}" >&2
  exit 1
fi

output_json="${tmp_dir}/control-plane.json"
nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/current-lab/intent.nix" \
  "${labs_path}/current-lab/inventory-clab.nix" \
  "${output_json}" >/dev/null

jq -e '
  .control_plane_model.data."mini-smt"."dns-resolver-config" as $site
  | $site.runtimeTargets."mini-smt-dns-resolver-config-access-dns" as $access
  | $site.runtimeTargets."mini-smt-dns-resolver-config-downstream-selector" as $downstream
  | ($access.services.dns // {}) as $dns
  | ($dns.forwarders // []) as $forwarders
  | ($dns.roles.recursion.outgoingInterfaces // []) as $recursionSources
  | ($access.runtimeOriginEgress.sourcePrefixes // []) as $originPrefixes
  | [
      ($downstream.forwardingIntent.rules // [])[]?
      | select((.relationId // "") == "runtime-origin-egress" or (.direction // "") == "forward-runtime-origin" or (.direction // "") == "selector-default-egress")
    ] as $runtimeRules
  | {
      forwarders: $forwarders,
      recursionSources: $recursionSources,
      runtimeOriginEgress: ($access.runtimeOriginEgress // null),
      runtimeRules: $runtimeRules,
      ok:
        ($forwarders | index("1.1.1.1") != null)
        and ($forwarders | index("9.9.9.9") != null)
        and ($forwarders | index("10.54.10.1") == null)
        and ($forwarders | index("fd42:540::1") == null)
        and ($forwarders | index("fd42:540:0:0:0:0:0:1") == null)
        and ($recursionSources | index("10.54.10.1") != null)
        and ($recursionSources | index("fd42:540:0:0:0:0:0:1") != null)
        and (($access.runtimeOriginEgress.enabled // false) == true)
        and any($originPrefixes[]?; (.family // null) == 4 and (.prefix // "") == "10.54.10.1/32")
        and any($originPrefixes[]?; (.family // null) == 6 and (.prefix // "") == "fd42:540:0:0:0:0:0:1/128")
        and any($runtimeRules[]?;
          any((.sourcePrefixes // [])[]?; (.family // null) == 4 and (.prefix // "") == "10.54.10.1/32")
          and any((.sourcePrefixes // [])[]?; (.family // null) == 6 and (.prefix // "") == "fd42:540:0:0:0:0:0:1/128")
        )
    }
  | select(.ok)
' "${output_json}" >/dev/null || {
  echo "FAIL FS-540 active-lab DNS service-origin egress: CPM must emit public forwarders, recursive source binding, and selector source-scoped runtime-origin egress for access-dns" >&2
  jq '
    .control_plane_model.data."mini-smt"."dns-resolver-config" as $site
    | {
        accessDns: {
          dns: $site.runtimeTargets."mini-smt-dns-resolver-config-access-dns".services.dns,
          runtimeOriginEgress: $site.runtimeTargets."mini-smt-dns-resolver-config-access-dns".runtimeOriginEgress
        },
        downstreamRuntimeRules: [
          ($site.runtimeTargets."mini-smt-dns-resolver-config-downstream-selector".forwardingIntent.rules // [])[]?
          | select((.relationId // "") == "runtime-origin-egress" or (.direction // "") == "forward-runtime-origin" or (.direction // "") == "selector-default-egress")
          | { relationId, direction, fromInterface, toInterface, sourcePrefixes }
        ]
      }
  ' "${output_json}" >&2
  exit 1
}

echo "PASS FS-540 active-lab DNS service-origin egress"
