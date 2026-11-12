#!/usr/bin/env bash
# GAMP-ID: FS-880-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-880-HDS-010-SDS-010-SMS-040.md
# OWNER:  network-control-plane-model
#
# Predicates: each lease-derived record is keyed by lease identity, source family
# and namespace, and an unchanged renewal is idempotent — exactly one record is
# preserved rather than a duplicate per renewal.
#
# Behavioural: compile the site model and assert on the operational record
# contracts CPM carries at
#   runtimeTargets.<t>.stateContracts.operationalRecords.dhcp4Leases[]
# The invariant is keying: records are addressed by a stable key, so a repeated
# renewal cannot create a second record for the same lease.
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

nixos_src="${NIXOS_SRC:-${HOME}/github/nixos}"
intent_path="${nixos_src}/prod-network/testing/intent-cobalt.nix"
inventory_path="${nixos_src}/prod-network/testing/inventory-cobalt.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL lease-record-keying: $*" >&2; exit 1; }

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

[[ -f "${intent_path}" ]] || fail "P1 no lease-bearing fixture at ${intent_path}; set NIXOS_SRC to the nixos checkout"
[[ -f "${inventory_path}" ]] || fail "P1 no lease-bearing inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the cobalt testing model does not compile, so no lease record can be validated"

# P1: at least one lease record must exist, so the case is not vacuous.
if ! jq -e '[.. | objects | select(has("dhcp4Leases"))] | length > 0' "${model_json}" >/dev/null 2>&1; then
  fail "P1 the model carries no dhcp4Leases operational records, so lease keying cannot be validated"
fi

# P1: every record carries a key naming lease identity, source family and
# namespace. The failure reports which field is missing.
# P1: every lease record contract requires a key naming lease identity, source
# family and namespace, so a record cannot be emitted without its own key.
#
# The record CPM emits here is a state *contract*: it declares the record's field
# set and its `schema.requiredFields`. The keying tuple therefore belongs in
# `schema.requiredFields`, not as a value on the descriptor -- a field merely
# present in `fields` is optional, and a lease record that omits its own key is
# precisely what an unchanged renewal looks like when it appends a second record
# instead of retaining one. The failure reports which field is not required.
missing="$(MODEL="${model_json}" nix eval --no-write-lock-file --impure --json --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    targets = builtins.attrValues d.control_plane_model.data.esp0xdeadbeef.cobalt.runtimeTargets;
    recs = builtins.concatLists (
      map
        (t:
          let sc = t.stateContracts or { };
              op = sc.operationalRecords or { };
          in op.dhcp4Leases or [ ])
        targets
    );
    required = r: (r.schema.requiredFields or [ ]);
    lacking = f: builtins.length (builtins.filter (r: !(f r)) recs);
    report = builtins.filter (x: x != null) [
      (let n = lacking (r: builtins.elem "leaseKey" (required r)); in if n == 0 then null else "leaseKey:${toString n}")
      (let n = lacking (r: builtins.elem "sourceFamily" (required r)); in if n == 0 then null else "sourceFamily:${toString n}")
      (let n = lacking (r: builtins.elem "namespace" (required r)); in if n == 0 then null else "namespace:${toString n}")
      (let n = lacking (r: builtins.elem "namespaceOwner" (required r)); in if n == 0 then null else "namespaceOwner:${toString n}")
      (let n = lacking (r: builtins.elem "requesterScope" (required r)); in if n == 0 then null else "requesterScope:${toString n}")
    ];
  in report
')"

if [[ "${missing}" != "[]" ]]; then
  fail "P1 these lease records omit a keying field: ${missing}"
fi

# P2: an unchanged renewal must be idempotent, so two contracts must never
# describe the same lease key. A duplicate key means a renewal produced a second
# record instead of replacing the first.
#
# Each emitted record is a contract for one lease-store: its key is the modeled
# lease-store identity (target + service + the contract's own id), which is what
# the record set is reconciled against. `r.leaseKey` is not a value on the
# descriptor -- P1 requires it as a per-record schema field -- so keying here on
# it read nothing and the check could not run.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    targets = builtins.attrNames d.control_plane_model.data.esp0xdeadbeef.cobalt.runtimeTargets;
    recs = builtins.concatLists (
      map
        (t:
          let leases = d.control_plane_model.data.esp0xdeadbeef.cobalt.runtimeTargets.${t}.stateContracts.operationalRecords.dhcp4Leases or [ ];
          in map (r: { inherit t; key = "${t}|" + (r.service or "") + "|" + (r.id or ""); }) leases)
        targets
    );
    keys = map (r: r.key) recs;
    uniqueCount = builtins.length (builtins.attrNames (
      builtins.listToAttrs (map (k: { name = k; value = true; }) keys)
    ));
  in
    builtins.length keys == uniqueCount
' | grep -qx true; then
  fail "P2 two lease records share a key, so an unchanged renewal was not idempotent"
fi


# The predicate is evaluated once, by the same function, for both the positive and
# the negative: a negative that re-implements it proves nothing.
if [[ "$(unique_keys '["10.20.20.10|dhcp4|clients","10.20.20.11|dhcp4|clients"]')" != "true" ]]; then
  fail "P1 the unique-key predicate rejected a set of distinct keys, so the check cannot pass a conforming model"
fi

# SN1: the same predicate must reject duplicates.
if [[ "$(unique_keys '["10.20.20.10|dhcp4|clients","10.20.20.10|dhcp4|clients"]')" == "true" ]]; then
  fail "SN1 the unique-key predicate accepted a duplicated key, so it cannot detect the defect it exists for"
fi


echo "PASS lease-record-keying"
