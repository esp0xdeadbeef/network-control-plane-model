#!/usr/bin/env bash
# GAMP-ID: FS-940-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() {
  echo "FAIL FS-940-HDS-010-SDS-010-SMS-020: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

parse_record() {
  local line="$1"
  unset fields
  declare -gA fields
  for token in ${line}; do
    [[ "${token}" == *=* ]] || continue
    fields["${token%%=*}"]="${token#*=}"
  done
}

field_equals() {
  local key="$1"
  local expected="$2"
  local actual="${fields[${key}]:-}"
  [[ "${actual}" == "${expected}" ]] || fail "expected ${key}=${expected}, got ${actual:-<missing>}"
}

field_present() {
  local key="$1"
  [[ -n "${fields[${key}]:-}" ]] || fail "missing required field ${key}"
}

validate_record_contract() {
  local line="$1"
  parse_record "${line}"

  local missing=()
  local required=(
    stage
    example
    status
    elapsed_ms
    threshold_ms
    threshold_status
    gate
    repo_revision
    repo_dirty
    locked_revisions
    timing_method
    host_class
    cache_state
    command
    upstream_cardinality
    downstream_cardinality
    excluded_runtime_stages
    diagnostic
  )
  if [[ "${fields[status]:-}" == "FAIL" ]]; then
    required+=(exit_code stderr_summary)
  fi

  for key in "${required[@]}"; do
    [[ -n "${fields[${key}]:-}" ]] || missing+=("${key}")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${fields[status]:-}" == "FAIL" ]]; then
    for key in command exit_code stderr_summary; do
      if [[ " ${missing[*]} " == *" ${key} "* ]]; then
        echo "diagnostic.stage-benchmark-command-failure-unrecorded"
        return 1
      fi
    done
  fi

  echo "diagnostic.stage-benchmark-metadata-missing"
  return 1
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

positive_out="${tmp_dir}/positive.out"
positive_err="${tmp_dir}/positive.err"

set +e
CPM_BENCH_THRESHOLD_MS=1 \
CPM_BENCH_SAMPLES=1 \
CPM_BENCH_EXAMPLES=s-router-public-overlay-service \
  bash "${repo_root}/benchmarks/fs940-semantic-eval.sh" >"${positive_out}" 2>"${positive_err}"
positive_status=$?
set -e

[[ "${positive_status}" -eq 0 ]] || {
  cat "${positive_out}" >&2
  cat "${positive_err}" >&2
  fail "phase-local threshold overrun must remain diagnostic when the measured command succeeds"
}

positive_record="$(rg '^BENCH fs940 ' "${positive_out}" || true)"
[[ -n "${positive_record}" ]] || fail "benchmark emitted no BENCH record"
validate_record_contract "${positive_record}" >/dev/null || fail "positive benchmark record failed metadata contract"
parse_record "${positive_record}"
field_equals stage control-plane-model
field_equals example s-router-public-overlay-service
field_equals status PASS
field_equals threshold_ms 1
field_equals threshold_status OVER_THRESHOLD
field_equals gate diagnostic
field_equals cache_state warm-required
field_equals command nix-eval-libBySystem.get_CPM
field_equals exit_code 0
field_equals stderr_summary none
field_equals diagnostic none
field_present locked_revisions
field_present host_class
[[ "${fields[timing_method]}" == date_ms_min_of_1 ]] || fail "unexpected timing_method=${fields[timing_method]}"
[[ "${fields[upstream_cardinality]}" == sites:* ]] || fail "missing upstream cardinality summary"
[[ "${fields[downstream_cardinality]}" == *sites:* ]] || fail "missing downstream cardinality summary"
[[ "${fields[excluded_runtime_stages]}" == *live-packet-validation* ]] || fail "runtime stages not excluded from semantic benchmark"

missing_out="${tmp_dir}/missing.out"
missing_err="${tmp_dir}/missing.err"
set +e
CPM_BENCH_EXAMPLES=__missing_fs940_fixture__ \
  bash "${repo_root}/benchmarks/fs940-semantic-eval.sh" >"${missing_out}" 2>"${missing_err}"
missing_status=$?
set -e
[[ "${missing_status}" -ne 0 ]] || fail "missing benchmark input unexpectedly passed"
missing_record="$(rg '^BENCH fs940 ' "${missing_err}" || true)"
[[ -n "${missing_record}" ]] || fail "missing input failure did not emit a structured BENCH record"
validate_record_contract "${missing_record}" >/dev/null || fail "missing input failure record failed metadata contract"
parse_record "${missing_record}"
field_equals status FAIL
field_equals command input-discovery
field_equals exit_code 66
field_equals stderr_summary missing_intent_or_inventory
field_equals diagnostic diagnostic.stage-benchmark-input-missing

bad_failure_record='BENCH fs940 stage=control-plane-model example=bad status=FAIL elapsed_ms=1 threshold_ms=3000 threshold_status=not-evaluated gate=diagnostic repo_revision=test repo_dirty=false locked_revisions=test timing_method=date_ms_min_of_1 host_class=test cache_state=warm-required upstream_cardinality=unknown downstream_cardinality=unknown excluded_runtime_stages=none diagnostic=diagnostic.stage-benchmark-command-failure-recorded'
if diagnostic="$(validate_record_contract "${bad_failure_record}")"; then
  fail "SN1 malformed failure record unexpectedly accepted"
fi
[[ "${diagnostic}" == "diagnostic.stage-benchmark-command-failure-unrecorded" ]] || fail "SN1 emitted ${diagnostic}"

bad_metadata_record='BENCH fs940 stage=control-plane-model example=bad status=PASS elapsed_ms=1 threshold_ms=3000 threshold_status=PASS gate=diagnostic command=nix-eval-libBySystem.get_CPM diagnostic=none'
if diagnostic="$(validate_record_contract "${bad_metadata_record}")"; then
  fail "SN2 malformed metadata record unexpectedly accepted"
fi
[[ "${diagnostic}" == "diagnostic.stage-benchmark-metadata-missing" ]] || fail "SN2 emitted ${diagnostic}"

echo "PASS FS-940-HDS-010-SDS-010-SMS-020 stage-budget cardinality benchmark"
