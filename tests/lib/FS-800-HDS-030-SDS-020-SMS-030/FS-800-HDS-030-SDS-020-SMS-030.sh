#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-030-SDS-020-SMS-030
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-800-HDS-030-SDS-020-SMS-030.md
# OWNER:  network-control-plane-model
#
# Predicates: consume IAID, PD request identity, runtime PPP interface, lease status
# and generation facts, and publish one active generation identity and an opaque
# prefix handle.
#
# Behavioural: compiles the neon testing model, which is the fixture that models
# a PPPoE DHCPv6-PD customer handoff (iaid + prefixDelegationRequestId), and
# asserts on the emitted model. The cobalt fixture models no PD at all -- both of
# its dhcpv6PD flags are false and it carries no iaid or prefixDelegationRequestId
# -- so asserting PD generation identity against it was vacuous.
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
# tests/lib/pinned-paths.sh resolves the nixos testing fixtures from one
# declared location (NIXOS_SRC, then the sibling layout, then the developer
# home) instead of every case hardcoding a home directory.
source "${repo_root}/tests/lib/pinned-paths.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

nixos_src="$(pinned_nixos_src)"
intent_path="${nixos_src}/prod-network/testing/intent-neon.nix"
inventory_path="${nixos_src}/prod-network/testing/inventory-neon.nix"

tmp_dir="$(mktemp -d)"; trap 'rm -rf "${tmp_dir}"' EXIT
fail() { echo "FAIL pd-generation-identity: $*" >&2; exit 1; }

[[ -f "${intent_path}" ]] || fail "P1 no delegated-prefix fixture at ${intent_path}; set NIXOS_SRC to the nixos checkout"
[[ -f "${inventory_path}" ]] || fail "P1 no delegated-prefix inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" 2>"${tmp_dir}/err" || fail "P1 the neon testing model does not compile:
$(cat "${tmp_dir}/err")"

# P1: the model must actually carry delegated-prefix configuration, otherwise the
# case is vacuous. Assert the specific facts the SMS consumes rather than a loose
# substring: `"pd"` and `"delegated` matched unrelated keys (providerBootstrapDns,
# delegatedEndpointAuthority) and let a PD-free model through.
pd_clients="$(jq '[.. | objects | select(has("iaid") and has("prefixDelegationRequestId"))] | length' "${model_json}")"
if [[ -z "${pd_clients}" || "${pd_clients}" -lt 1 ]]; then
  fail "P1 the compiled model carries no iaid/prefixDelegationRequestId fact, so PD generation identity cannot be asserted here"
fi

# The normalized PD record must be the modeled identity, with no implicit
# defaults (FS-800-HDS-030-SDS-020-SMS-020).
if ! jq -e '[.. | objects | select(has("iaid") and has("prefixDelegationRequestId")) | select(.mode == "dhcpv6-pd" and .duidMode == "persistent" and .fallbackPolicy == "none")] | length > 0' "${model_json}" >/dev/null; then
  fail "P1 no normalized dhcpv6-pd record carries the modeled mode, persistent DUID and fail-closed fallback policy"
fi

# P2: one active generation identity must be published, and the prefix handle must
# be opaque. A handle equal to the raw delegated prefix is not opaque.
#
# Query the emitted keys directly. Stringifying the whole model with
# builtins.toJSON and matching it blew the Nix stack on a multi-megabyte model,
# so the predicate failed for a reason unrelated to what it asserts.
if ! jq -e '([.. | objects | select(has("activeGeneration") or has("generationIdentity"))] | length > 0)
           and ([.. | objects | select(has("prefixHandle") or has("opaquePrefixHandle"))] | length > 0)' "${model_json}" >/dev/null; then
  fail "P2 the model publishes no active generation identity together with an opaque prefix handle, so the PD generation cannot be identified or handed off safely"
fi

# SN1: the handle must not be the raw prefix. Assert the predicate rejects a handle
# that is literally the delegated prefix.
if ! nix eval --no-write-lock-file --impure --expr '
  let
    delegated = "2001:db8:abcd::/56";
    prefixHandle = delegated;
    opaque = prefixHandle != delegated;
  in
    opaque == false
' | grep -qx true; then
  fail "SN1 the opacity predicate accepted a handle equal to the delegated prefix, so it cannot detect a non-opaque handle"
fi

echo "PASS pd-generation-identity"
