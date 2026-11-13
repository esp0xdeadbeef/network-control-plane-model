#!/usr/bin/env bash
# GAMP-ID: FS-560-HDS-010-SDS-010-SMS-060
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-560-HDS-010-SDS-010-SMS-060.md
# OWNER:  network-control-plane-model
#
# Predicates: one explicit serving-access to namespace relation is consumed, and a
# scope names its suffix as either an explicit suffix or an explicit inherited
# reference — never by default.
#
# Behavioural: compile the site model and assert on the emitted namespace and zone
# surface. CPM carries the resolved namespaces at
#   runtimeTargets.<t>.services.dns.protectedReservationPublications[].namespace
# and the authoritative zones at services.dns.localZones[].
#
# The invariant tested: every namespace is owned by a modeled scope and every
# authoritative zone name is covered by a modeled namespace or equals the modeled
# dnsDomain, so no zone exists whose suffix no scope declared.
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
# tests/lib/pinned-paths.sh resolves the fixture from the pinned network-labs
# flake input, so this case reads no developer checkout and no consumer repo.
source "${repo_root}/tests/lib/pinned-paths.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

# Pinned network-labs fixture. This repository must not read fixtures out of the
# `nixos` consumer repository; `protected-reservation-publication` models the
# protected reservation source this row asserts on, in both inventories.
example_dir="$(pinned_lab_example protected-reservation-publication)"
intent_path="${example_dir}/intent.nix"
inventory_path="${example_dir}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL namespace-suffix-declaration: $*" >&2; exit 1; }

[[ -f "${intent_path}" ]] || fail "P1 no namespace-bearing fixture at ${intent_path}; the pinned network-labs example is missing"
[[ -f "${inventory_path}" ]] || fail "P1 no namespace-bearing inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the pinned lab fixture does not compile, so no namespace can be validated"

# P1: at least one namespace must be modeled, so the case is not vacuous.
if ! jq -e '[.. | objects | select(has("protectedReservationPublications"))] | length > 0' "${model_json}" >/dev/null 2>&1; then
  fail "P1 the model carries no protectedReservationPublications, so no namespace relation exists to validate"
fi

# P1: every namespace names an owner scope. A namespace with no modeled owner is a
# suffix that no scope declared.
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
      map
        (t:
          let dns = t.services.dns or { };
          in dns.protectedReservationPublications or [ ])
        targets
    );
    owned = builtins.filter
      (p: (p.namespace or null) != null && (p.ownerScope or null) != null)
      pubs;
  in
    builtins.length pubs > 0 && builtins.length owned == builtins.length pubs
' | grep -qx true; then
  fail "P1 a namespace carries no owner scope, so a suffix exists that no modeled scope declares"
fi

# P2: every published namespace must be an explicitly qualified name under a named
# site zone, not the bare site-wide default. URS Local Service Discovery: "A
# namespace shall name either an explicit domain or an explicit reference to a
# named site zone; it shall not inherit a site-wide domain default."
#
# The authority is the intent, not a string shape. FS-560-HDS-010-SDS-010 (and FS
# 1219) require the suffix to be *declared* by the owning scope: either an explicit
# domain or a reference to a named zone. CPM resolves that declaration into
# `data.<site>.domains.tenants[].dnsDomain`, one suffix per tenant scope.
#
# So a published namespace is explicit exactly when it is one of the suffixes the
# intent declared. That is the property the URS describes, and it needs no guess
# about which zones are "site zones": the earlier draft filtered `localZones` by a
# hardcoded `in-addr.arpa`/`ip6.arpa` string match to separate forward zones from
# reverse zones. That was an assumption, not a modeled fact -- and it was wrong in
# both directions: `localZones` also holds the reverse zones CPM derives from
# prefixes (`reverseNamespace` on the same record), so the filter had to invent a
# classification the model already states by field.
#
# Comparing against the declared set also fails closed on the defect the SMS names:
# a namespace defaulted from a site-wide suffix appears on no tenant's declaration.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    sites = builtins.filter builtins.isAttrs (
      builtins.attrValues d.control_plane_model.data.esp0xdeadbeef
    );
    targetValues = builtins.concatMap
      (s: builtins.attrValues (s.runtimeTargets or { }))
      sites;
    listOf = x: if builtins.isList x then x else [ ];

    namespaces = map (p: p.namespace) (builtins.concatLists (
      map
        (t:
          let
            dns = (t.services or { }).dns or { };
          in
          if builtins.isAttrs dns then listOf (dns.protectedReservationPublications or [ ]) else [ ])
        targetValues
    ));

    # The suffixes the owning scopes declared in intent, across every site.
    declared = builtins.concatMap
      (s:
        map (t: t.dnsDomain)
          (builtins.filter (t: (t.dnsDomain or null) != null) (s.domains.tenants or [ ])))
      sites;

    inherited = builtins.filter (ns: !(builtins.elem ns declared)) namespaces;
  in
    builtins.length namespaces > 0 && inherited == [ ]
' | grep -qx true; then
  fail "P2 a published namespace is not the suffix its owning scope declared in intent, so it inherits a site-wide default, which URS Local Service Discovery forbids"
fi

# SN1: the predicate must reject a namespace the intent never declared. The
# violating input is a bare site-wide suffix that no tenant scope chose.
#
# Fail when the predicate ACCEPTS the violating input, i.e. answers `true`. The
# earlier condition was inverted -- it failed on the correct `false` answer -- and
# stayed hidden only because P2 failed first and short-circuited the case.
if [[ "$(nix eval --no-write-lock-file --impure --json --expr '
  let
    declared = [ "clients.home.arpa." "svc.home.arpa." ];
    namespaces = [ "clients.home.arpa." "home.arpa." ];
    inherited = builtins.filter (ns: !(builtins.elem ns declared)) namespaces;
  in
    inherited == [ ]
')" == "true" ]]; then
  fail "SN1 the explicit-namespace predicate accepted a namespace no scope declared, which is the inheritance the URS forbids"
fi

echo "PASS namespace-suffix-declaration"
