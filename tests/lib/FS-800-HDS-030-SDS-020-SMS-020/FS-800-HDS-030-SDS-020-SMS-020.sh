#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-030-SDS-020-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
fixture="${repo_root}/tests/fixtures/fs800-pppoe-ipv6-pd-contract.nix"
nixpkgs_path="$(REPO_ROOT="${repo_root}" nix eval --impure --raw --expr '
  (builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT")).inputs.nixpkgs.outPath
')"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

evaluate_case() {
  local case_name="$1"
  nix-instantiate --eval --strict --json "${fixture}" \
    --arg repoRoot "${repo_root}" \
    --arg nixpkgsPath "${nixpkgs_path}" \
    --argstr caseName "${case_name}"
}

positive="$(evaluate_case valid)"
jq -e '
  .interface == "provider-handoff"
  and .runtimeInterface == "ppp-test"
  and .mtu == 1492
  and .ipv6 == {
    "defaultRoute": true,
    "duidMode": "persistent",
    "fallbackPolicy": "none",
    "iaid": 7,
    "ipv4Mode": "disabled",
    "mode": "dhcpv6-pd",
    "prefixDelegationRequestId": 11,
    "resolverMode": "disabled",
    "routerSolicitation": false
  }
' <<<"${positive}" >/dev/null

expect_failure() {
  local case_name="$1"
  local diagnostic="$2"
  local stderr_path="${tmp_dir}/${case_name}.stderr"
  if evaluate_case "${case_name}" >"${tmp_dir}/${case_name}.out" 2>"${stderr_path}"; then
    echo "FAIL FS-800: ${case_name} was accepted" >&2
    exit 1
  fi
  grep -F "${diagnostic}" "${stderr_path}" >/dev/null
  if grep -F -e '/run/secrets/test-' -e 'ppp-test' "${stderr_path}" >/dev/null; then
    echo "FAIL FS-800: protected or site-specific values leaked in diagnostics" >&2
    exit 1
  fi
}

expect_failure missing-interface '.services.pppoe.client.interface is required'
expect_failure missing-runtime-interface '.services.pppoe.client.runtimeInterface is required'
expect_failure missing-mtu '.services.pppoe.client.mtu: must be a positive integer'
expect_failure missing-iaid '.services.pppoe.client.ipv6.iaid: must be a positive integer'
expect_failure missing-pd-request-id '.services.pppoe.client.ipv6.prefixDelegationRequestId: must be a positive integer'
expect_failure missing-ipv6-default-route '.services.pppoe.client.ipv6.defaultRoute: must be a boolean'
expect_failure ipv4-enabled '.services.pppoe.client.ipv6.ipv4Mode: must be one of: disabled'
expect_failure router-solicitation '.services.pppoe.client.ipv6.routerSolicitation: must be false for DHCPv6-PD-only mode'
expect_failure fallback-enabled '.services.pppoe.client.ipv6.fallbackPolicy: must be one of: none'
expect_failure resolver-enabled '.services.pppoe.client.ipv6.resolverMode: must be one of: disabled'
expect_failure invented-field '.services.pppoe.client.ipv6: contains unsupported PPPoE IPv6/PD fields'
expect_failure changed-iaid '.services.pppoe.client.ipv6.iaid: must be a positive integer'
expect_failure changed-pd-request-id '.services.pppoe.client.ipv6.prefixDelegationRequestId: must be a positive integer'

echo 'PASS FS-800-HDS-030-SDS-020-SMS-020: explicit PPPoE IPv6/PD contract'
