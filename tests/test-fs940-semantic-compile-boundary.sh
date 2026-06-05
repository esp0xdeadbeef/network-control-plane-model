#!/usr/bin/env bash
# GAMP-ID: FS-940-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
foreign_cwd="${NETWORK_FOREIGN_CWD:-/home/deadbeef/github/network-codex-agent}"

fail() {
  echo "$1" >&2
  exit 1
}

[[ -d "${foreign_cwd}" ]] || foreign_cwd="/tmp"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

bench_out="${tmp_dir}/bench.out"
own_rev="$(git -C "${repo_root}" rev-parse HEAD)"

(
  cd "${foreign_cwd}"
  CPM_BENCH_THRESHOLD_MS=15000 \
  CPM_BENCH_EXAMPLES="s-router-overlay-dns-lane-policy" \
  "${repo_root}/benchmarks/fs940-semantic-eval.sh" \
    >"${bench_out}"
)

[[ "$(grep -c '^BENCH fs940 ' "${bench_out}")" -eq 1 ]] \
  || fail "FS-940 benchmark boundary proof did not emit exactly one focused BENCH record"

line="$(cat "${bench_out}")"

[[ "${line}" == *"stage=control-plane-model"* ]] \
  || fail "FS-940 benchmark boundary proof did not classify the CPM stage"
[[ "${line}" == *"example=s-router-overlay-dns-lane-policy"* ]] \
  || fail "FS-940 benchmark boundary proof did not report the selected controlled example"
[[ "${line}" == *"status=PASS"* ]] \
  || fail "FS-940 benchmark boundary proof did not pass"
[[ "${line}" == *"repo_revision=${own_rev}"* ]] \
  || fail "FS-940 benchmark boundary proof did not bind output to the CPM repository revision"
[[ "${line}" == *"locked_revisions="*"network-compiler="* ]] \
  || fail "FS-940 benchmark boundary proof did not report locked upstream revisions"
[[ "${line}" == *"network-forwarding-model="* ]] \
  || fail "FS-940 benchmark boundary proof did not report the locked NFM revision"
[[ "${line}" == *"network-labs="* ]] \
  || fail "FS-940 benchmark boundary proof did not report the locked source-example revision"
[[ "${line}" == *"cache_state=warm-required"* ]] \
  || fail "FS-940 benchmark boundary proof did not classify warm-cache expectations"
[[ "${line}" == *"command=nix-eval-libBySystem.get_CPM"* ]] \
  || fail "FS-940 benchmark boundary proof did not identify the semantic-eval command surface"
[[ "${line}" == *"excluded_runtime_stages=nix-build,container-image-build,vm-deployment,containerlab-deployment,boot,live-packet-validation,provider-calls,cache-misses"* ]] \
  || fail "FS-940 benchmark boundary proof did not keep runtime stages outside the semantic compile boundary"

echo "PASS fs940-semantic-compile-boundary"
