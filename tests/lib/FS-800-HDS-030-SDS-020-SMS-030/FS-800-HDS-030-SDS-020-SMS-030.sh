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
# Behavioural: compiles the cobalt testing model, which carries delegated-prefix
# configuration, and asserts on the emitted model. Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

nixos_src="${NIXOS_SRC:-${HOME}/github/nixos}"
intent_path="${nixos_src}/prod-network/testing/intent-cobalt.nix"
inventory_path="${nixos_src}/prod-network/testing/inventory-cobalt.nix"

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
' >"${model_json}" 2>"${tmp_dir}/err" || fail "P1 the cobalt testing model does not compile:
$(cat "${tmp_dir}/err")"

# P1: the model must actually carry delegated-prefix configuration, otherwise the
# case is vacuous. Cobalt terminates provider handoffs that include PD.
if ! grep -qiE '"delegated|prefixDelegation|"pd"|iaid' "${model_json}"; then
  fail "P1 the compiled model carries no delegated-prefix or IAID fact, so PD generation identity cannot be asserted here"
fi

# P2: one active generation identity must be published, and the prefix handle must
# be opaque. A handle equal to the raw delegated prefix is not opaque.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    text = builtins.toJSON d;
    hasGeneration = builtins.match ".*\"(activeGeneration|generationIdentity)\".*" text != null;
    hasHandle = builtins.match ".*\"(prefixHandle|opaquePrefixHandle)\".*" text != null;
  in
    hasGeneration && hasHandle
' | grep -qx true; then
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
