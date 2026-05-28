#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ "${NETWORK_REPO_SWEEP:-0}" != "1" && "${NETWORK_REPO_DIRECT_TEST_OK:-0}" != "1" ]]; then
  echo "WARN: direct repo tests are partial; set NETWORK_REPO_DIRECT_TEST_OK=1 for intentional focused runs, or run network-codex-agent/scripts/s-router-full-lab-rebuild-loop.sh for the locked full network-* sweep plus live validation." >&2
fi

default_jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
jobs="${TEST_JOBS:-${default_jobs}}"
test_timeout_seconds="${TEST_TIMEOUT_SECONDS:-${NETWORK_REPO_TEST_TIMEOUT_SECONDS:-1800}}"
if ! [[ "${jobs}" =~ ^[0-9]+$ ]] || [[ "${jobs}" -lt 1 ]]; then
  echo "error: TEST_JOBS must be a positive integer, got '${jobs}'" >&2
  exit 2
fi
if ! [[ "${test_timeout_seconds}" =~ ^[0-9]+$ ]] || [[ "${test_timeout_seconds}" -lt 1 ]]; then
  echo "error: TEST_TIMEOUT_SECONDS must be a positive integer, got '${test_timeout_seconds}'" >&2
  exit 2
fi

tests=(
  test-nix-file-loc.sh
  test-resolved-inventory-secret-facts-contract.sh
  test-dns-killswitch-policy-matrix.sh
  test-policy-deny-precedence.sh
  test-provider-overlay-runtime-interface-name.sh
  test-delegated-overlay-public-egress.sh
  test-upstream-selector-nebula-underlay-core-transit.sh
  test-runtime-underlay-endpoint-source-routes.sh
  test-transit-default-routes-are-classified.sh
  test-small-prefix-dhcp-pools.sh
  test-network-labs-inventory-sweep.sh
  integration-tri-site-dual-wan-overlay-integration-bgp
)

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

declare -A pid_to_name=()
declare -A pid_to_log=()
declare -A pid_to_start=()
running=0
failures=0

run_integration() {
  local jq_cmd
  if command -v jq >/dev/null 2>&1; then
    jq_cmd=(jq)
  else
    jq_cmd=(nix run nixpkgs#jq --)
  fi

  local example_repo
  example_repo="$(
    nix flake archive --json "path:${ROOT}" \
      | "${jq_cmd[@]}" -er '.inputs["network-labs"].path'
  )"

  local scenario="tri-site-dual-wan-overlay-integration-bgp"
  local input="${example_repo}/examples/${scenario}/intent.nix"
  local input_inventory="${example_repo}/examples/${scenario}/inventory-nixos.nix"
  local output
  output="$(mktemp)"

  if [[ ! -f "${input}" || ! -f "${input_inventory}" ]]; then
    echo "[!] Missing inputs for scenario '${scenario}'"
    echo "    INPUT='${input}'"
    echo "    INVENTORY='${input_inventory}'"
    exit 1
  fi

  echo "[*] Using scenario: ${scenario}"
  echo "[*] INPUT: ${input}"
  echo "[*] INVENTORY: ${input_inventory}"
  echo "[*] Running control-plane-model..."
  nix run "path:${ROOT}#compile-and-build-control-plane-model" -- "${input}" "${input_inventory}" "${output}" >/dev/null
  echo "[*] Validating JSON..."
  "${jq_cmd[@]}" empty "${output}" >/dev/null
  echo "[*] Output summary..."
  "${jq_cmd[@]}" -c '{version, enterprises: (.control_plane_model.data | keys)}' "${output}"
  rm -f "${output}"
}

run_one() {
  local test_name="$1"
  if [[ "${test_name}" == integration-* ]]; then
    run_integration
  else
    timeout "${test_timeout_seconds}" "${ROOT}/tests/${test_name}"
  fi
}

wait_for_one() {
  local finished_pid
  local status=0
  wait -n -p finished_pid || status=$?

  local name="${pid_to_name[${finished_pid}]}"
  local log_file="${pid_to_log[${finished_pid}]}"
  local start="${pid_to_start[${finished_pid}]}"
  local elapsed=$((SECONDS - start))
  unset "pid_to_name[${finished_pid}]"
  unset "pid_to_log[${finished_pid}]"
  unset "pid_to_start[${finished_pid}]"
  running=$((running - 1))

  if (( status == 0 )); then
    printf 'PASS %s (%ss)\n' "${name}" "${elapsed}"
  else
    printf 'FAIL %s (exit %s, %ss)\n' "${name}" "${status}" "${elapsed}" >&2
    awk -v prefix="[${name}] " '{ print prefix $0 }' "${log_file}" >&2
    failures=$((failures + 1))
  fi
}

printf 'running %s tests with TEST_JOBS=%s\n' "${#tests[@]}" "${jobs}"
for test_name in "${tests[@]}"; do
  log_file="${tmp_dir}/${test_name}.log"
  printf 'START %s\n' "${test_name}"
  run_one "${test_name}" >"${log_file}" 2>&1 &
  pid_to_name[$!]="${test_name}"
  pid_to_log[$!]="${log_file}"
  pid_to_start[$!]="${SECONDS}"
  running=$((running + 1))

  if (( running >= jobs )); then
    wait_for_one
  fi
done

while (( running > 0 )); do
  wait_for_one
done

if (( failures > 0 )); then
  printf 'FAIL network-control-plane-model: %s test(s) failed\n' "${failures}" >&2
  exit 1
fi

printf 'PASS network-control-plane-model: %s tests\n' "${#tests[@]}"
