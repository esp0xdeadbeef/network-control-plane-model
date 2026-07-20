#!/usr/bin/env bash
# GAMP-ID: FS-260-HDS-010-SDS-010-SMS-040
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

validate_selector_fabric_links() {
  local input="$1"
  jq -e '
    def selector_targets:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | select(($target.value.role // "") | test("selector$"))
        | {
            target: $target.key,
            role: $target.value.role,
            interfaces: (($target.value.effectiveRuntimeRealization.interfaces // {}) | to_entries)
          }
      ];

    def fabric_ifaces:
      [
        selector_targets[]
        | . as $target
        | $target.interfaces[]
        | select(.value.fabricLink?)
        | {
            target: $target.target,
            role: $target.role,
            name: .key,
            value: .value
          }
      ];

    def bad_fabric:
      [
        fabric_ifaces[]
        | select(
            .value.sourceKind != "p2p"
            or .value.adapterClass != "selector-fabric-link"
            or .value.virtualAdapter != true
            or .value.hostFacing != false
            or .value.exclusionReason != "selector-fabric-link"
            or .value.p2pPurpose != "selector-fabric"
            or .value.fabricLink.kind != "selector-fabric-link"
            or .value.fabricLink.link != .value.backingRef.name
            or .value.fabricLink.transport.hostFacing != false
            or (.value | has("adapterName"))
            or (.value | has("attach"))
          )
      ];

    def selector_fabric_without_record:
      [
        selector_targets[]
        | .interfaces[]
        | select(.value.adapterClass == "selector-fabric-link" and (.value | has("fabricLink") | not))
        | .key
      ];

    selector_targets as $targets
    | fabric_ifaces as $fabric
    | bad_fabric as $bad
    | selector_fabric_without_record as $missingFabric
    | {
        trace: "FS-260-HDS-010-SDS-010-SMS-040",
        selectorTargetCount: ($targets | length),
        selectorFabricLinkCount: ($fabric | length),
        badFabricCount: ($bad | length),
        missingFabricRecordCount: ($missingFabric | length),
        badFabric: $bad,
        missingFabricRecord: $missingFabric
      }
    | select(
        .selectorTargetCount > 0
        and .selectorFabricLinkCount > 0
        and .badFabricCount == 0
        and .missingFabricRecordCount == 0
      )
  ' "${input}" >/dev/null
}

mutate_first_selector_fabric() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def first_fabric_ids:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | select(($target.value.role // "") | test("selector$"))
        | $target.value.effectiveRuntimeRealization.interfaces
        | to_entries[]
        | select(.value.fabricLink?)
        | [$enterprise.key, $site.key, $target.key, .key]
      ][0];

    first_fabric_ids as $ids
    | ["control_plane_model", "data", $ids[0], $ids[1], "runtimeTargets", $ids[2], "effectiveRuntimeRealization", "interfaces", $ids[3]] as $p
    | if $mutation == "host-facing-fanout" then
        setpath($p + ["hostFacing"]; true)
        | setpath($p + ["virtualAdapter"]; false)
        | setpath($p + ["direction"]; "ingress")
      elif $mutation == "missing-fabric-link" then
        delpaths([$p + ["fabricLink"]])
      elif $mutation == "renderer-convenience" then
        setpath($p + ["adapterName"]; "eth-selector-fanout")
        | setpath($p + ["attach"]; { kind: "bridge", bridge: "br-selector-fanout" })
      else
        .
      end
  ' "${input}" > "${output}"
}

assert_rejects() {
  local input="$1"
  local label="$2"

  if validate_selector_fabric_links "${input}"; then
    echo "FAIL FS-260-HDS-010-SDS-010-SMS-040 ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-260-HDS-010-SDS-010-SMS-040 ${label}: seeded violation rejected"
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

validate_selector_fabric_links "${nixos_output}"
validate_selector_fabric_links "${clab_output}"

for output in "${nixos_output}" "${clab_output}"; do
  host_facing="${tmp_dir}/$(basename "${output}").host-facing.json"
  missing="${tmp_dir}/$(basename "${output}").missing-fabric-link.json"
  renderer="${tmp_dir}/$(basename "${output}").renderer.json"

  mutate_first_selector_fabric "${output}" "${host_facing}" "host-facing-fanout"
  mutate_first_selector_fabric "${output}" "${missing}" "missing-fabric-link"
  mutate_first_selector_fabric "${output}" "${renderer}" "renderer-convenience"

  assert_rejects "${host_facing}" "host-facing-fanout"
  assert_rejects "${missing}" "missing-fabric-link"
  assert_rejects "${renderer}" "renderer-convenience"

  validate_selector_fabric_links "${output}"
done

echo "PASS FS-260-HDS-010-SDS-010-SMS-040 selector-fabric-links-realization"
