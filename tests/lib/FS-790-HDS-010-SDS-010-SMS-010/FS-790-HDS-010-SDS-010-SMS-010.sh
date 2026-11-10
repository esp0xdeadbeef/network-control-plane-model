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
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

nixos_src="${NIXOS_SRC:-${HOME}/github/nixos}"
intent_path="${nixos_src}/prod-network/testing/intent-cobalt.nix"
inventory_path="${nixos_src}/prod-network/testing/inventory-cobalt.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL public-ingress-fixture-row: $*" >&2; exit 1; }

[[ -f "${intent_path}" ]] || fail "P1 no public-ingress fixture at ${intent_path}; set NIXOS_SRC to the nixos checkout"
[[ -f "${inventory_path}" ]] || fail "P1 no public-ingress inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'.compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the cobalt testing model does not compile, so no ingress row can be validated"

# P1: at least one public-ingress authority must exist, so the case is not
# vacuous.
if ! jq -e '[.. | objects | select(has("publicIngressTupleAuthority"))] | length > 0' "${model_json}" >/dev/null 2>&1; then
  fail "P1 the model carries no publicIngressTupleAuthority, so no ingress row can be validated"
fi

# P1: every authority names public surface, allowed source scope and exposure
# identity. The failure names which fact is missing.
missing="$(MODEL="${model_json}" nix eval --no-write-lock-file --impure --json --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    relations = d.control_plane_model.data.esp0xdeadbeef.cobalt.communicationContract.allowedRelations;
    withAuth = builtins.filter (r: r ? publicIngressTupleAuthority) relations;
    auths = map (r: r.publicIngressTupleAuthority) withAuth;
    lacking = f: builtins.length (builtins.filter (a: !(f a)) auths);
    report = builtins.filter (x: x != null) [
      (let n = lacking (a: (a.publicSurface or null) != null); in if n == 0 then null else "publicSurface:${toString n}")
      (let n = lacking (a: (a.sourceScope or null) != null); in if n == 0 then null else "sourceScope:${toString n}")
      (let n = lacking (a: (a.exposureIdentity or null) != null); in if n == 0 then null else "exposureIdentity:${toString n}")
    ];
  in report
')"

if [[ "${missing}" != "[]" ]]; then
  fail "P1 these public-ingress authorities omit a required fact: ${missing}"
fi

# P2: a split port-forward must be represented by separate rows. Two authorities
# that share an exposure identity but differ in port must not be merged into one
# record, so the emitted set must contain one record per (identity, port, proto).
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    relations = d.control_plane_model.data.esp0xdeadbeef.cobalt.communicationContract.allowedRelations;
    withAuth = builtins.filter (r: r ? publicIngressTupleAuthority) relations;
    key = r:
      let a = r.publicIngressTupleAuthority;
          ports = builtins.concatLists (map (m: m.dports or [ ]) (r.match or [ ]));
          protos = map (m: m.proto or "") (r.match or [ ]);
      in builtins.toJSON {
        inherit ports protos;
        surface = a.publicSurface or null;
      };
    keys = map key withAuth;
  in
    builtins.length keys == builtins.length (builtins.attrNames (
      builtins.listToAttrs (map (k: { name = k; value = true; }) keys)
    ))
' | grep -qx true; then
  fail "P2 two public-ingress authorities share an identical surface/port/proto key, so a split port-forward was emitted as duplicate rows instead of distinct ones"
fi

echo "PASS public-ingress-fixture-row"
