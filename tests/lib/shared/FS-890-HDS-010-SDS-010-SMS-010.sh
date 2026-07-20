#!/usr/bin/env bash
# GAMP-ID: FS-890-HDS-010-SDS-010
# GAMP-ID: FS-890-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-890-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-890-HDS-010-SDS-010-SMS-030
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
archive_json="${tmp_dir}/flake-archive.json"
cpm_json="${tmp_dir}/cpm.json"
trap 'rm -rf "${tmp_dir}"' EXIT

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_path="$(
  jq -er '.inputs["network-labs"].path' "${archive_json}"
)"

if [[ -f "${labs_path}/GAMP/SAT/intent.nix" ]]; then
  source_dir="${labs_path}/GAMP/SAT"
elif [[ -f "${labs_path}/GAMP/HAT/emulated-isp-residential-testnet/intent.nix" ]]; then
  source_dir="${labs_path}/GAMP/HAT/emulated-isp-residential-testnet"
else
  echo "FAIL fs890-operational-record-schema-runtime-target: missing controlled GAMP/SAT or GAMP/HAT lab source under ${labs_path}" >&2
  exit 1
fi

intent_path="${source_dir}/intent.nix"
if [[ -f "${source_dir}/inventory.nix" ]]; then
  inventory_path="${source_dir}/inventory.nix"
else
  inventory_path="${source_dir}/inventory-nixos.nix"
fi

nix run \
  --no-write-lock-file \
  --extra-experimental-features 'nix-command flakes' \
  "${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${inventory_path}" \
  "${cpm_json}" >/dev/null

jq -e '
  def has_all($expected; $actual):
    all($expected[]; . as $expected_value | $actual | index($expected_value) != null);
  def has_none($rejected; $actual):
    all($rejected[]; . as $rejected_value | $actual | index($rejected_value) == null);
  def record_contracts:
    [
      .control_plane_model.data
      | to_entries[].value
      | to_entries[].value.runtimeTargets
      | to_entries[]
      | . as $target
      | (
          ($target.value.stateContracts.operationalRecords.dhcp4Leases // [])[],
          ($target.value.stateContracts.operationalRecords.dhcpv6Leases // [])[],
          ($target.value.stateContracts.operationalRecords.dnsService // [])[],
          ($target.value.stateContracts.operationalRecords.dnsResolver // [])[]
        )
      | . + { __runtimeTargetName: $target.key }
    ];
  [
    "recordType",
    "timestampSource",
    "site",
    "context",
    "runtimeFactSet",
    "modelProvenance",
    "decision",
    "reason",
    "redactionClass"
  ] as $required
  | [ "tenant" ] as $conditional
  | [
      "time",
      "node",
      "service",
      "eventType",
      "clientOrAddress",
      "action",
      "result",
      "severity"
    ] as $placeholders
  | record_contracts as $records
  | ($records | length) > 0
    and any($records[];
      .targetName == .__runtimeTargetName
      and .service == "dhcp4"
      and .format == "jsonl"
      and .stateClass == "operational-record"
    )
    and all($records[];
      has_all($required; .fields)
      and has_all($conditional; .fields)
      and has_none($placeholders; .fields)
      and .schema.requiredFields == $required
      and .schema.conditionalFields == $conditional
      and .schema.incompleteEvidence.classification == "incomplete-evidence"
      and .schema.incompleteEvidence.whenMissingFields == [
        "site",
        "context",
        "runtimeFactSet",
        "modelProvenance"
      ]
      and .schema.incompleteEvidence.promotionAllowed == false
    )
' "${cpm_json}" >/dev/null || {
  echo "FAIL fs890-operational-record-schema-runtime-target: generated runtime target operational record schema does not match FS-890" >&2
  exit 1
}

echo "PASS fs890-operational-record-schema-runtime-target"
