#!/usr/bin/env bash
# GAMP-ID: FS-760-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

hat_dir="/home/deadbeef/github/network-labs/HAT/emulated-isp-residential-testnet"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

compiler_json="${tmp_dir}/compiler.json"
compiler_signed_json="${tmp_dir}/compiler-signed.json"
nfm_json="${tmp_dir}/nfm.json"
nixos_json="${tmp_dir}/cpm-nixos.json"
clab_json="${tmp_dir}/cpm-clab.json"

compiler_repo="${NETWORK_COMPILER_REPO:-/home/deadbeef/github/network-compiler}"
nfm_repo="${NETWORK_FORWARDING_MODEL_REPO:-/home/deadbeef/github/network-forwarding-model}"

OUTPUT_COMPILER_SIGNED_JSON="${compiler_signed_json}" \
  nix run --no-warn-dirty --no-write-lock-file "path:${compiler_repo}#compile" -- \
  "${hat_dir}/intent.nix" >"${compiler_json}"

nix run --no-warn-dirty --no-write-lock-file "path:${nfm_repo}#debug" -- \
  "${compiler_json}" >"${nfm_json}"

jq -e '
  any(.enterprise.esp0xdeadbeef.site[]?.accessSpaceDiscovery.sharedServicePolicyAtoms[]?;
    .id == "fs760-receiver-discovery-policy"
    and .service == "hat-receiver-discovery"
    and .responderScope == "iot"
    and any(.requesterScopes[]?; . == "trusted")
  )
' "${nfm_json}" >/dev/null || {
  echo "FAIL fs760-receiver-discovery-policy-materialization: NFM input lacks fs760-receiver-discovery-policy" >&2
  exit 1
}

assert_cpm_output() {
  local label="$1"
  local output_json="$2"

  jq -e --arg label "${label}" '
    def udp_ports($rule):
      [($rule.matches // [])[]? | select(.proto == "udp") | (.dports // [])[]?] | sort;

    def has_tcp_payload_port($rule):
      any(($rule.matches // [])[]?;
        .proto == "tcp"
        and any((.dports // [])[]?; . == 8008 or . == 8009)
      );

    def fs760_atom($site):
      any($site.accessSpaceDiscovery.sharedServicePolicyAtoms[]?;
        .id == "fs760-receiver-discovery-policy"
        and .service == "hat-receiver-discovery"
        and .source.outputPath[-1] == "fs760-receiver-discovery-policy"
      );

    def fs760_renderer_atom($site):
      any($site.rendererContracts.portableMeaning.requiredBehavior.accessSpaceDiscovery.sharedServicePolicyAtoms[]?;
        .id == "fs760-receiver-discovery-policy"
        and .service == "hat-receiver-discovery"
        and .source.outputPath[-1] == "fs760-receiver-discovery-policy"
      );

    def fs760_rules($site):
      [
        ($site.runtimeTargets // {})
        | to_entries[]
        | select(.value.role == "policy")
        | (.value.forwardingIntent.rules // [])[]
        | select(.relationId == "fs760-receiver-discovery-policy")
      ];

    .control_plane_model.data.esp0xdeadbeef as $enterprise
    | ["site-a", "site-b"] as $siteNames
    | all($siteNames[];
        . as $siteName
        | $enterprise[$siteName] as $site
        | fs760_rules($site) as $rules
        | fs760_atom($site)
          and fs760_renderer_atom($site)
          and ($rules | length == 1)
          and all($rules[];
            .action == "accept"
            and .trafficType == "cast-discovery"
            and .priority == 119
            and .from.kind == "tenant"
            and .from.name == "trusted"
            and .to.kind == "tenant"
            and .to.name == "iot"
            and ((.fromInterface // "") != "")
            and ((.toInterface // "") != "")
            and .fromInterface != .toInterface
            and udp_ports(.) == [1900, 5353]
            and (has_tcp_payload_port(.) | not)
            and .intent.kind == "shared-service-discovery-policy"
            and .intent.policyAtomId == "fs760-receiver-discovery-policy"
            and .intent.service == "hat-receiver-discovery"
            and .intent.source.outputPath[-1] == "fs760-receiver-discovery-policy"
          )
      )
  ' "${output_json}" >/dev/null || {
    echo "FAIL fs760-receiver-discovery-policy-materialization: ${label} output lost atom or scoped discovery-only rules" >&2
    jq -S '
      .control_plane_model.data.esp0xdeadbeef
      | to_entries[]
      | {
          site: .key,
          atoms: [
            .value.accessSpaceDiscovery.sharedServicePolicyAtoms[]?
            | select(.id == "fs760-receiver-discovery-policy")
          ],
          rendererAtoms: [
            .value.rendererContracts.portableMeaning.requiredBehavior.accessSpaceDiscovery.sharedServicePolicyAtoms[]?
            | select(.id == "fs760-receiver-discovery-policy")
          ],
          rules: [
            (.value.runtimeTargets // {})
            | to_entries[]
            | select(.value.role == "policy")
            | (.value.forwardingIntent.rules // [])[]
            | select(.relationId == "fs760-receiver-discovery-policy")
          ]
        }
    ' "${output_json}" >&2
    exit 1
  }
}

nix run --no-warn-dirty --no-write-lock-file "path:${repo_root}#debug" -- \
  "${nfm_json}" \
  "${hat_dir}/inventory-nixos.nix" \
  "${nixos_json}" >/dev/null
assert_cpm_output "HAT NixOS" "${nixos_json}"

nix run --no-warn-dirty --no-write-lock-file "path:${repo_root}#debug" -- \
  "${nfm_json}" \
  "${hat_dir}/inventory-clab.nix" \
  "${clab_json}" >/dev/null
assert_cpm_output "HAT CLAB" "${clab_json}"

echo "PASS fs760-receiver-discovery-policy-materialization"
