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
# tests/lib/pinned-paths.sh resolves the nixos testing fixtures from one
# declared location (NIXOS_SRC, then the sibling layout, then the developer
# home) instead of every case hardcoding a home directory.
source "${repo_root}/tests/lib/pinned-paths.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

# BLOCKED on a fixture that models a protected reservation set.
#
# `network-*` repositories must not read fixtures out of the `nixos` consumer
# repository, and this case still does. It cannot be repointed at a pinned
# `network-labs` example, and the reason is measured, not assumed:
#
# CPM emits `protectedReservationPublications` only for a DHCP advertisement whose
# `reservationSource` declares all of
#
#     schema      = "gamp-protected-reservation-set-v1"
#     sourceClass = "protected"
#     sourceFile  = <non-empty>
#
# (src/cpm/ControlModule/runtime-targets/dns-contracts.nix, the publication gate),
# and whose domain is a namespace the resolver forwards or answers locally. Every
# pinned lab example was measured against the pinned lock:
#
#   single-wan                     dhcp4 adv 3  publications 0
#   single-wan-bgp                 dhcp4 adv 3  publications 0
#   dual-wan                       dhcp4 adv 2  publications 0
#   multi-enterprise               dhcp4 adv 3  publications 0
#   priority-stability             dhcp4 adv 3  publications 0
#   policy-any-to-any-fw           dhcp4 adv 3  publications 0
#   single-wan-with-nebula         dhcp4 adv 3  publications 0
#   s-router-overlay-dns-lane-policy  dhcp4 adv 8  publications 0
#   s-router-public-overlay-service   dhcp4 adv 8  publications 0
#
# No lab inventory declares `namePublication` or a
# `gamp-protected-reservation-set-v1` reservation source. In `single-wan` the
# advertisements carry domain `lan.` while the resolver's localZones hold only the
# derived reverse zones (10.20.10.in-addr.arpa. and the ip6.arpa. pairs), so the
# forward namespace nothing owns is dropped by skipPublicationFor before the
# source gate is even reached.
#
# Weakening the assertions to fit an empty publication set would delete what the
# row proves. The fix is a `network-labs` example plus inventory that models a
# protected reservation set; until one exists the case reads the model that has
# the facts and states the dependency here.
# Pinned network-labs fixture. This repository must not read fixtures out of the
# `nixos` consumer repository; `protected-reservation-publication` models the
# protected reservation source this row asserts on, in both inventories.
example_dir="$(pinned_lab_example protected-reservation-publication)"
intent_path="${example_dir}/intent.nix"
inventory_path="${example_dir}/inventory-nixos.nix"

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
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the pinned lab fixture does not compile, so no publication can be validated"

# P1: at least one publication must exist, so the case is not vacuous.
if ! jq -e '[.. | objects | select(has("protectedReservationPublications"))] | length > 0' "${model_json}" >/dev/null 2>&1; then
  fail "P1 the model carries no protectedReservationPublications, so no public view exists to validate"
fi

# P1: each publication is bound to a declared namespace owner and carries an
# explicit record-class list, so the public view does not inherit internal records.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    sites = builtins.filter builtins.isAttrs (
      builtins.attrValues d.control_plane_model.data.esp0xdeadbeef
    );
    targets = builtins.concatMap
      (s: builtins.attrValues (s.runtimeTargets or { }))
      sites;
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
    sites = builtins.filter builtins.isAttrs (
      builtins.attrValues d.control_plane_model.data.esp0xdeadbeef
    );
    targets = builtins.concatMap
      (s: builtins.attrValues (s.runtimeTargets or { }))
      sites;
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
# `builtins.unique` does not exist, so the predicate threw on evaluation and the
# case failed for a reason unrelated to what it asserts. Count distinct owners
# explicitly: one namespace is conflicted when its publications name more than
# one distinct owner scope.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    sites = builtins.filter builtins.isAttrs (
      builtins.attrValues d.control_plane_model.data.esp0xdeadbeef
    );
    targets = builtins.concatMap
      (s: builtins.attrValues (s.runtimeTargets or { }))
      sites;
    pubs = builtins.concatLists (
      map (t: (t.services.dns or { }).protectedReservationPublications or [ ]) targets
    );
    byNs = builtins.groupBy (p: p.namespace) pubs;
    distinctCount =
      values:
      builtins.length (builtins.attrNames (
        builtins.listToAttrs (map (v: { name = builtins.toJSON v; value = true; }) values)
      ));
    ownersOf = ns: distinctCount (map (p: p.ownerScope) byNs.${ns});
    conflicts = builtins.filter
      (ns: ownersOf ns > 1)
      (builtins.attrNames byNs);
  in
    conflicts == [ ]
' | grep -qx true; then
  fail "P2 one namespace is published for more than one owner scope, so the public view is not owned by exactly one scope"
fi

# SN1: the one-owner predicate must reject a namespace claimed by two owners. The
# violating input is a synthetic publication set with one namespace under two scopes.
if [[ "$(nix eval --no-write-lock-file --impure --json --expr '
  let
    pubs = [
      { namespace = "clients.home.arpa."; ownerScope = "cobalt-clients"; }
      { namespace = "clients.home.arpa."; ownerScope = "neon-clients"; }
    ];
    byNs = builtins.groupBy (p: p.namespace) pubs;
    distinctCount =
      values:
      builtins.length (builtins.attrNames (
        builtins.listToAttrs (map (v: { name = builtins.toJSON v; value = true; }) values)
      ));
    ownersOf = ns: distinctCount (map (p: p.ownerScope) byNs.${ns});
    conflicts = builtins.filter (ns: ownersOf ns > 1) (builtins.attrNames byNs);
  in
    conflicts == [ ]
')" == "true" ]]; then
  fail "SN1 the one-owner predicate accepted a namespace claimed by two owner scopes"
fi

# SN2: an unknown record class must be rejected. The violating input names a class
# the model never declares.
# Fail when the predicate ACCEPTS the violating input, i.e. answers `true`. The
# condition was inverted -- it failed on the predicate correct `false` answer --
# and only surfaced once P2 and SN1 stopped short-circuiting the case.
if [[ "$(nix eval --no-write-lock-file --impure --json --expr '
  let
    classes = [ "A" "AAAA" "BOGUS" ];
    known = [ "A" "AAAA" "PTR" "TXT" "MX" "SRV" "CNAME" ];
  in
    builtins.all (c: builtins.elem c known) classes
')" == "true" ]]; then
  fail "SN2 the record-class predicate accepted an unrecognised class"
fi

echo "PASS public-view-separation"
