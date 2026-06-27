#!/usr/bin/env bash
# GAMP-ID: FS-265-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

validate_access_cardinality() {
  local input="$1"

  jq -e '
    def access_targets:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | select(($target.value.role // "") == "access")
        | {
            target: $target.key,
            role: $target.value.role,
            interfaces: (($target.value.effectiveRuntimeRealization.interfaces // {}) | to_entries)
          }
      ];

    def host_facing($target):
      $target.interfaces | map(select(.value.hostFacing == true));

    def valid_access_surface($iface):
      (
        ($iface.value.sourceKind == "tenant"
          and $iface.value.adapterClass == "tenant-role-surface"
          and $iface.value.direction == "ingress"
          and (($iface.value.virtualAdapter // false) == false))
        or
        ($iface.value.sourceKind == "p2p"
          and $iface.value.adapterClass == "p2p-realization"
          and $iface.value.direction == "egress"
          and (($iface.value.virtualAdapter // false) == false))
      );

    access_targets as $targets
    | [
        $targets[]
        | host_facing(.) as $host
        | {
            target,
            hostFacingCount: ($host | length),
            ingressCount: ($host | map(select(.value.direction == "ingress")) | length),
            egressCount: ($host | map(select(.value.direction == "egress")) | length),
            invalidHostFacing: ($host | map(select(valid_access_surface(.) | not)) | map(.key)),
            virtualHostFacing: ($host | map(select((.value.virtualAdapter // false) == true)) | map(.key)),
            p2pIngress: ($host | map(select(.value.sourceKind == "p2p" and .value.direction == "ingress")) | map(.key)),
            tenantEgress: ($host | map(select(.value.sourceKind == "tenant" and .value.direction == "egress")) | map(.key))
          }
        | select(
            .hostFacingCount != 2
            or .ingressCount != 1
            or .egressCount != 1
            or (.invalidHostFacing | length) != 0
            or (.virtualHostFacing | length) != 0
            or (.p2pIngress | length) != 0
            or (.tenantEgress | length) != 0
          )
      ] as $violations
    | {
        trace: "FS-265-HDS-010-SDS-010-SMS-010",
        accessTargetCount: ($targets | length),
        violations: $violations
      }
    | select(.accessTargetCount > 0 and (.violations | length) == 0)
  ' "${input}" >/dev/null
}

mutate_first_access() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def first_access_ids:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[]
        | select((.value.role // "") == "access")
        | [$enterprise.key, $site.key, .key]
      ][0];

    first_access_ids as $ids
    | ["control_plane_model", "data", $ids[0], $ids[1], "runtimeTargets", $ids[2], "effectiveRuntimeRealization", "interfaces"] as $p
    | if $mutation == "extra-tenant" then
        setpath($p + ["fs265-extra-tenant-fanout"]; {
          sourceKind: "tenant",
          adapterClass: "tenant-role-surface",
          direction: "ingress",
          hostFacing: true,
          virtualAdapter: false,
          exclusionReason: "FS-265-HDS-010-SDS-010-SMS-010 seeded tenant fanout"
        })
      elif $mutation == "extra-p2p" then
        setpath($p + ["fs265-extra-p2p-fanout"]; {
          sourceKind: "p2p",
          adapterClass: "p2p-realization",
          direction: "egress",
          hostFacing: true,
          virtualAdapter: false,
          exclusionReason: "FS-265-HDS-010-SDS-010-SMS-010 seeded p2p fanout"
        })
      elif $mutation == "virtual" then
        setpath($p + ["fs265-overlay-promoted-host-facing"]; {
          sourceKind: "overlay",
          adapterClass: "overlay",
          direction: "egress",
          hostFacing: true,
          virtualAdapter: true,
          exclusionReason: "FS-265-HDS-010-SDS-010-SMS-010 seeded virtual promotion"
        })
      elif $mutation == "missing-ingress" then
        (getpath($p) | to_entries | map(select(.value.hostFacing == true and .value.direction == "ingress")) | .[0].key) as $ingress
        | delpaths([$p + [$ingress]])
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

  if validate_access_cardinality "${input}"; then
    echo "FAIL FS-265-HDS-010-SDS-010-SMS-010 ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-265-HDS-010-SDS-010-SMS-010 ${label}: seeded violation rejected"
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

validate_access_cardinality "${nixos_output}"
validate_access_cardinality "${clab_output}"

for output in "${nixos_output}" "${clab_output}"; do
  extra_tenant="${tmp_dir}/$(basename "${output}").extra-tenant.json"
  extra_p2p="${tmp_dir}/$(basename "${output}").extra-p2p.json"
  missing_ingress="${tmp_dir}/$(basename "${output}").missing-ingress.json"
  missing_egress="${tmp_dir}/$(basename "${output}").missing-egress.json"
  virtual="${tmp_dir}/$(basename "${output}").virtual.json"

  mutate_first_access "${output}" "${extra_tenant}" "extra-tenant"
  mutate_first_access "${output}" "${extra_p2p}" "extra-p2p"
  mutate_first_access "${output}" "${missing_ingress}" "missing-ingress"
  mutate_first_access "${output}" "${missing_egress}" "missing-egress"
  mutate_first_access "${output}" "${virtual}" "virtual"

  assert_rejects "${extra_tenant}" "extra-tenant-fanout"
  assert_rejects "${extra_p2p}" "extra-p2p-fanout"
  assert_rejects "${missing_ingress}" "missing-ingress"
  assert_rejects "${missing_egress}" "missing-egress"
  assert_rejects "${virtual}" "virtual-host-facing-promotion"

  validate_access_cardinality "${output}"
done

echo "PASS FS-265-HDS-010-SDS-010-SMS-010 access host-facing cardinality"
