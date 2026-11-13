#!/usr/bin/env bash
# GAMP-ID: FS-790-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-790-HDS-010-SDS-010-SMS-010.md
# OWNER:  network-control-plane-model
#
# Predicates: each public ingress fixture row is validated for public surface,
# allowed source scope and exposure identity, and split port-forward behaviour
# requires separate rows.
#
# Behavioural: compile the site model and assert on the emitted
# `publicIngressTupleAuthority` records that CPM carries on allowed relations.
# The invariant is that every public-ingress authority names the three facts the
# SMS requires, so a row with an unidentified surface or source cannot reach a
# renderer.
#
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

# Pinned network-labs fixture. This repository must not read fixtures out of the
# `nixos` consumer repository; `protected-reservation-publication` models a
# public-ingress relation for the site resolver, with udp and tcp tuples, so the
# row has a split port-forward to validate.
example_dir="$(pinned_lab_example protected-reservation-publication)"
intent_path="${example_dir}/intent.nix"
inventory_path="${example_dir}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL public-ingress-fixture-row: $*" >&2; exit 1; }

unique_keys() {
  # Pass the keys through the environment and read them with builtins.getEnv.
  # Splice-based quoting (`'"$1"'`) produced a literal whose inner double quotes
  # closed the Nix string early, so the expression never parsed and this
  # self-check could not run at all. An env var has no quoting to get wrong.
  KEYS_JSON="$1" nix eval --no-write-lock-file --impure --json --expr '
    let keys = builtins.fromJSON (builtins.getEnv "KEYS_JSON");
    in builtins.length (builtins.attrNames (
         builtins.listToAttrs (map (k: { name = k; value = true; }) keys)))
       == builtins.length keys
  '
}

[[ -f "${intent_path}" ]] || fail "P1 no public-ingress fixture at ${intent_path}; set NIXOS_SRC to the nixos checkout"
[[ -f "${inventory_path}" ]] || fail "P1 no public-ingress inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the pinned lab fixture does not compile, so no ingress row can be validated"

# At least one emitted public-ingress row must exist, so the case is not vacuous.
#
# Assert on the emitted rows, not on the intent mirror. FS-790-HDS-010-SDS-010-SMS-010
# requires "public-ingress row identity records for platform-neutral model stages"
# (Emitted Interfaces), and CPM publishes those per row and per tuple on
# `runtimeTargets.<t>.natIntent.publicIngress[]`. The
# `communicationContract.allowedRelations[].publicIngressTupleAuthority` record the
# case used to read is the modeled *input* authority (surface, source scope, target
# service/endpoint, tuples) and carries no identity by construction, so the identity
# predicate could never hold there.
if ! jq -e '[.control_plane_model.data.esp0xdeadbeef | to_entries[] | .value.runtimeTargets[]? | .natIntent.publicIngress[]?] | length > 0' "${model_json}" >/dev/null 2>&1; then
  fail "P1 the model carries no emitted public-ingress row, so no ingress row can be validated"
fi

# P1: every emitted row names public surface, allowed source scope and exposure
# identity. The failure names which fact is missing and on how many rows.
missing="$(jq -c '
  [ .control_plane_model.data.esp0xdeadbeef | to_entries[] | .value.runtimeTargets[]? | .natIntent.publicIngress[]? ]
  | {
      total: length,
      publicSurface: (map(select((.publicSurface // null) == null)) | length),
      sourceScope: (map(select((.sourceScope // null) == null)) | length),
      exposureIdentity: (map(select((.exposureIdentity // null) == null)) | length)
    }
  | . as $r
  | ["publicSurface", "sourceScope", "exposureIdentity"]
  | map(select(($r[.] ) > 0) | "\(.):\($r[.])")
' "${model_json}")"

if [[ "${missing}" != "[]" ]]; then
  fail "P1 these public-ingress rows omit a required fact: ${missing}"
fi

# P2: a split port-forward must be represented by separate rows. Two authorities
# P2: a split port-forward must be represented by separate rows. Rows that share
# an exposure identity must not be merged into one record, so the emitted set must
# contain exactly one row per exposure identity.
if ! jq -e '
  [ .control_plane_model.data.esp0xdeadbeef | to_entries[] | .value.runtimeTargets[]? | .natIntent.publicIngress[]? ]
  | map(.exposureIdentity)
  | length == (unique | length)
' "${model_json}" >/dev/null 2>&1; then
  fail "P2 two public-ingress rows share an identical exposure identity, so a split port-forward was emitted as duplicate rows instead of distinct ones"
fi

# P2: the split itself must be visible: a service exposed on the same surface and
# endpoint over more than one protocol or port is several exposures, each with its
# own identity, so a row never grants another ingress leg.
if ! jq -e '
  [ .control_plane_model.data.esp0xdeadbeef | to_entries[] | .value.runtimeTargets[]? | .natIntent.publicIngress[]? ]
  | group_by(.publicSurface + "|" + (.target.endpoint // ""))
  | all(.[]; (map(.exposureIdentity) | length) == (map(.exposureIdentity) | unique | length))
' "${model_json}" >/dev/null 2>&1; then
  fail "P2 one public surface/endpoint pair reuses an exposure identity across rows, so one row authorizes more than one ingress leg"
fi


# The predicate is evaluated once, by the same function, for both the positive and
# the negative: a negative that re-implements it proves nothing.
if [[ "$(unique_keys '["tcp:4242:1.2.3.4","udp:4242:1.2.3.4"]')" != "true" ]]; then
  fail "P1 the unique-key predicate rejected a set of distinct keys, so the check cannot pass a conforming model"
fi

# SN1: the same predicate must reject duplicates.
if [[ "$(unique_keys '["tcp:4242:1.2.3.4","tcp:4242:1.2.3.4"]')" == "true" ]]; then
  fail "SN1 the unique-key predicate accepted a duplicated key, so it cannot detect the defect it exists for"
fi


echo "PASS public-ingress-fixture-row"
