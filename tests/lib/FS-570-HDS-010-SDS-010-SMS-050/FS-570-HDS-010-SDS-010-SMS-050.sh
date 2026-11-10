#!/usr/bin/env bash
# GAMP-ID: FS-570-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-570-HDS-010-SDS-010-SMS-050.md
# OWNER:  network-control-plane-model
#
# Predicates: a public view is a distinct object of a resolver context, independent
# of the internal view's local and lease namespaces, and only explicitly modeled
# public records are published.
#
# Behavioural: compile the site model and assert on the publication records CPM
# carries at
#   runtimeTargets.<t>.services.dns.protectedReservationPublications[]
# Each names a namespace, an owner scope and its record classes. The invariant is
# that publication is bound to a declared namespace owner and carries an explicit
# record-class set, so the public view cannot inherit the internal view's records.
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

fail() { echo "FAIL public-view-separation: $*" >&2; exit 1; }

[[ -f "${intent_path}" ]] || fail "P1 no publication-bearing fixture at ${intent_path}; set NIXOS_SRC to the nixos checkout"
[[ -f "${inventory_path}" ]] || fail "P1 no publication-bearing inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'.compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the cobalt testing model does not compile, so no publication can be validated"

# P1: at least one publication must exist, so the case is not vacuous.
if ! jq -e '[.. | objects | select(has("protectedReservationPublications"))] | length > 0' "${model_json}" >/dev/null 2>&1; then
  fail "P1 the model carries no protectedReservationPublications, so no public view exists to validate"
fi

# P1: each publication is bound to a declared namespace owner and carries an
# explicit record-class list, so the public view does not inherit internal records.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    targets = builtins.attrValues d.control_plane_model.data.esp0xdeadbeef.cobalt.runtimeTargets;
    pubs = builtins.concatLists (
      map (t: (t.services.dns or { }).protectedReservationPublications or [ ]) targets
    );
    bound = builtins.filter
      (p:
        (p.namespace or null) != null
        && (p.ownerScope or null) != null
        && builtins.length (p.recordClasses or [ ]) > 0)
      pubs;
  in
    builtins.length pubs > 0 && builtins.length bound == builtins.length pubs
' | grep -qx true; then
  fail "P1 a publication has no namespace owner or no explicit record classes, so the public view is not a distinct object with its own records"
fi

# P2: the record classes must be a known DNS class set. An unknown class means the
# public view is carrying records the model never declared.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    targets = builtins.attrValues d.control_plane_model.data.esp0xdeadbeef.cobalt.runtimeTargets;
    pubs = builtins.concatLists (
      map (t: (t.services.dns or { }).protectedReservationPublications or [ ]) targets
    );
    classes = builtins.concatLists (map (p: p.recordClasses or [ ]) pubs);
    known = [ "A" "AAAA" "PTR" "TXT" "MX" "SRV" "CNAME" ];
  in
    builtins.all (c: builtins.elem c known) classes
' | grep -qx true; then
  fail "P2 a publication declares an unrecognised record class, so the public view carries records the model did not declare"
fi

# P2: one namespace must belong to exactly one owner scope, because the public
# view is owned by a single scope.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    targets = builtins.attrValues d.control_plane_model.data.esp0xdeadbeef.cobalt.runtimeTargets;
    pubs = builtins.concatLists (
      map (t: (t.services.dns or { }).protectedReservationPublications or [ ]) targets
    );
    byNs = builtins.groupBy (p: p.namespace) pubs;
    ownersOf = ns: builtins.unique (map (p: p.ownerScope) byNs.${ns});
    conflicts = builtins.filter
      (ns: builtins.length (ownersOf ns) > 1)
      (builtins.attrNames byNs);
  in
    conflicts == [ ]
' | grep -qx true; then
  fail "P2 one namespace is published for more than one owner scope, so the public view is not owned by exactly one scope"
fi

echo "PASS public-view-separation"
