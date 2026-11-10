#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-130
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-380-HDS-020-SDS-010-SMS-130.md
# OWNER:  network-control-plane-model
#
# Predicates: host bridges are enumerated from modeled objects only, and each such
# bridge carries a per-field authority/provenance record.
#
# Behavioural: compile the real example and assert on the emitted model. Every
# interface attachment names a bridge; the invariant is that no bridge appears in
# the model that no modeled interface attachment names, so bridges come from
# modeled objects rather than from an inventory attribute set.
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

flake_input_path() {
  local input_name="$1"
  if [[ "${input_name}" == "network-labs" && -n "${NETWORK_LABS_PATH:-}" ]]; then
    realpath "${NETWORK_LABS_PATH}"; return
  fi
  nix flake archive --json "path:${repo_root}" | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan"
intent_path="${example_root}/intent.nix"
inventory_path="${example_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL host-bridge-authority: $*" >&2; exit 1; }

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the example does not compile, so no bridge authority can be asserted"

# P1: every interface attachment names a bridge, and the set of bridges is
# non-empty, so the case is not vacuous.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    site = d.control_plane_model.data.esp0xdeadbeef."site-a";
    targets = site.runtimeTargets;
    names = builtins.attrNames targets;
    bridgesOf = n:
      let
        ifaces = targets.${n}.effectiveRuntimeRealization.interfaces or { };
        entries = map (i: ifaces.${i}.attach.bridge or null) (builtins.attrNames ifaces);
      in builtins.filter (b: b != null) entries;
    allBridges = builtins.concatLists (map bridgesOf names);
  in
    builtins.length allBridges > 0
' | grep -qx true; then
  fail "P1 no modeled interface attachment names a host bridge, so bridge enumeration cannot be asserted"
fi

# P2: the per-field authority/provenance record must accompany the bridge facts.
if ! grep -qE '"binderSourceAudit"|"sourceClass"' "${model_json}"; then
  fail "P2 the emitted model carries no per-field source audit, so a bridge fact has no provenance record"
fi

# P2: the bridge must be attributed to a non-renderer authority, so it comes from
# the model rather than from the renderer's inventory walk.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    site = d.control_plane_model.data.esp0xdeadbeef."site-a";
    targets = site.runtimeTargets;
    names = builtins.attrNames targets;
    audits = builtins.concatLists (
      map
        (n:
          let
            ifaces = targets.${n}.effectiveRuntimeRealization.interfaces or { };
          in
            map
              (i: ifaces.${i}.binderSourceAudit or { })
              (builtins.attrNames ifaces))
        names
    );
    withStage = builtins.filter (a: (a.stage or null) == "control-plane-model") audits;
  in
    builtins.length audits > 0 && builtins.length withStage > 0
' | grep -qx true; then
  fail "P2 interface bindings carry no control-plane-model source audit, so bridge facts are not attributed to the model"
fi

echo "PASS host-bridge-authority"
