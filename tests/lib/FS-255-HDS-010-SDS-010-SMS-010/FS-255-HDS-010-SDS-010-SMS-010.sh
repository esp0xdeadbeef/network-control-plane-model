#!/usr/bin/env bash
# GAMP-ID: FS-255-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

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

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"
nixos_output="${tmp_dir}/nixos-cpm.json"
clab_output="${tmp_dir}/clab-cpm.json"

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

validate_core_cardinality() {
  local input="$1"
  jq -e '
    def core_targets:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | select(($target.value.role // "") | startswith("core"))
        | {
            target: $target.key,
            role: $target.value.role,
            interfaces: (($target.value.effectiveRuntimeRealization.interfaces // {}) | to_entries)
          }
      ];

    def host_facing($target):
      $target.interfaces | map(select(.value.hostFacing == true));

    def valid_host_surface($iface):
      ($iface.value.hostFacing == true
       and $iface.value.virtualAdapter == false
       and (
         ($iface.value.direction == "ingress" and $iface.value.adapterClass == "p2p-realization")
         or
         ($iface.value.direction == "egress")
       ));

    core_targets as $targets
    | [
        $targets[]
        | host_facing(.) as $host
        | {
            target,
            hostFacingCount: ($host | length),
            ingressCount: ($host | map(select(.value.direction == "ingress")) | length),
            egressCount: ($host | map(select(.value.direction == "egress")) | length),
            invalidHostFacing: ($host | map(select(valid_host_surface(.) | not)) | map(.key)),
            virtualHostFacing: ($host | map(select(.value.virtualAdapter == true)) | map(.key))
          }
        | select(
            .hostFacingCount != 2
            or .ingressCount != 1
            or .egressCount != 1
            or (.invalidHostFacing | length) != 0
            or (.virtualHostFacing | length) != 0
          )
      ] as $violations
    | {
        trace: "FS-255-HDS-010-SDS-010-SMS-010",
        coreTargetCount: ($targets | length),
        violations: $violations
      }
    | select(.coreTargetCount > 0 and (.violations | length) == 0)
  ' "${input}" >/dev/null
}

mutate_first_core() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def first_core_ids:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[]
        | select((.value.role // "") | startswith("core"))
        | [$enterprise.key, $site.key, .key]
      ][0];

    first_core_ids as $ids
    | ["control_plane_model", "data", $ids[0], $ids[1], "runtimeTargets", $ids[2], "effectiveRuntimeRealization", "interfaces"] as $p
    | if $mutation == "fanout" then
        setpath($p + ["fs255-extra-p2p-fanout"]; {
          sourceKind: "p2p",
          adapterClass: "p2p-realization",
          direction: "ingress",
          hostFacing: true,
          virtualAdapter: false,
          exclusionReason: "FS-255-HDS-010-SDS-010-SMS-010 seeded fanout"
        })
      elif $mutation == "renderer" then
        setpath($p + ["eth-renderer-convenience"]; {
          sourceKind: "renderer-convenience",
          adapterClass: "runtime-name-heuristic",
          direction: "egress",
          hostFacing: true,
          virtualAdapter: false,
          runtimeIfName: "eth99",
          exclusionReason: "FS-255-HDS-010-SDS-010-SMS-010 seeded renderer convenience"
        })
      elif $mutation == "missing-egress" then
        (getpath($p) | to_entries | map(select(.value.hostFacing == true and .value.direction == "egress")) | .[0].key) as $egress
        | delpaths([$p + [$egress]])
      else
        .
      end
  ' "${input}" > "${output}"
}

assert_rejects() {
  local input="$1"
  local label="$2"

  if validate_core_cardinality "${input}"; then
    echo "FAIL FS-255-HDS-010-SDS-010-SMS-010 ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-255-HDS-010-SDS-010-SMS-010 ${label}: seeded violation rejected"
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

validate_core_cardinality "${nixos_output}"
validate_core_cardinality "${clab_output}"

for output in "${nixos_output}" "${clab_output}"; do
  fanout="${tmp_dir}/$(basename "${output}").fanout.json"
  missing="${tmp_dir}/$(basename "${output}").missing-egress.json"
  renderer="${tmp_dir}/$(basename "${output}").renderer.json"

  mutate_first_core "${output}" "${fanout}" "fanout"
  mutate_first_core "${output}" "${missing}" "missing-egress"
  mutate_first_core "${output}" "${renderer}" "renderer"

  assert_rejects "${fanout}" "fanout-injection"
  assert_rejects "${missing}" "missing-egress"
  assert_rejects "${renderer}" "renderer-convenience-injection"

  validate_core_cardinality "${output}"
done

echo "PASS FS-255-HDS-010-SDS-010-SMS-010 core host-facing cardinality"
