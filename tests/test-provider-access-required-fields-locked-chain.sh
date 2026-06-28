#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-011
# GAMP-SCOPE: software-integration-test
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
inventory_path="${hat_dir}/inventory-nixos.nix"
provider_table_path="${hat_dir}/provider-access-fixture-table.nix"

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

write_inventory_case() {
  local path="$1"
  local scenario_expr="$2"

  cat >"${path}" <<EOF
let
  base = import ${inventory_path};
  providerTable = import ${provider_table_path};
  pppoeNixosScenario = ${scenario_expr};
in
base
// {
  controlPlane = base.controlPlane // {
    providerAccess = base.controlPlane.providerAccess // {
      scenarios = base.controlPlane.providerAccess.scenarios // {
        pppoeNixos = pppoeNixosScenario;
        pppoeClab = providerTable.pppoeClab;
      };
    };
  };
}
EOF
}

expect_failure() {
  local name="$1"
  local inventory="$2"
  local expected="$3"
  local output_path="${tmp_dir}/${name}.json"
  local stderr_path="${tmp_dir}/${name}.stderr"

  if build_cpm "${inventory}" "${output_path}" 2>"${stderr_path}"; then
    echo "FAIL provider-access-required-fields-locked-chain: ${name} unexpectedly evaluated" >&2
    exit 1
  fi

  if [[ -e "${output_path}" ]]; then
    echo "FAIL provider-access-required-fields-locked-chain: ${name} produced CPM output after rejection" >&2
    exit 1
  fi

  if ! grep -Fq "${expected}" "${stderr_path}"; then
    echo "FAIL provider-access-required-fields-locked-chain: ${name} missing diagnostic" >&2
    echo "expected substring: ${expected}" >&2
    cat "${stderr_path}" >&2
    exit 1
  fi
}

write_inventory_case \
  "${tmp_dir}/positive.nix" \
  'providerTable.pppoeNixos'

build_cpm "${tmp_dir}/positive.nix" "${tmp_dir}/positive.json"

write_inventory_case \
  "${tmp_dir}/missing-provider-ipv4.nix" \
  'providerTable.pppoeNixos // {
    provider = providerTable.pppoeNixos.provider // {
      addressDelivery = builtins.removeAttrs providerTable.pppoeNixos.provider.addressDelivery [ "ipv4" ];
    };
  }'

write_inventory_case \
  "${tmp_dir}/missing-failure-expectation.nix" \
  'builtins.removeAttrs providerTable.pppoeNixos [ "failureExpectation" ]'

write_inventory_case \
  "${tmp_dir}/missing-probe-intent.nix" \
  'builtins.removeAttrs providerTable.pppoeNixos [ "probeIntent" ]'

expect_failure \
  "missing-provider-ipv4" \
  "${tmp_dir}/missing-provider-ipv4.nix" \
  "FS-800-HDS-010-SDS-011-SMS-010: provider-access required field 'provider.addressDelivery.ipv4' must be present before CPM handoff"

expect_failure \
  "missing-failure-expectation" \
  "${tmp_dir}/missing-failure-expectation.nix" \
  "FS-800-HDS-010-SDS-011-SMS-010: provider-access required field 'failureExpectation' must be present before CPM handoff"

expect_failure \
  "missing-probe-intent" \
  "${tmp_dir}/missing-probe-intent.nix" \
  "FS-800-HDS-010-SDS-011-SMS-010: provider-access required field 'probeIntent' must be present before CPM handoff"

echo "PASS provider-access-required-fields-locked-chain"
