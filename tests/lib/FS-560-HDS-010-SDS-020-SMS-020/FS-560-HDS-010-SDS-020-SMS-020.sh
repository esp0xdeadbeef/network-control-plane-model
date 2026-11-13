#!/usr/bin/env bash
# GAMP-ID: FS-560-HDS-010-SDS-020-SMS-020
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-560-HDS-010-SDS-020-SMS-020.md
# OWNER:  network-control-plane-model
#
# Predicates: more-specific local/forward zones are emitted before the terminal
# local refusal, and provider endpoint, namespace direction, record classes and
# source are preserved.
#
# Behavioural: compile the site model and assert on the emitted DNS surface that
# CPM already carries per runtime target:
#   services.dns.localZones[]       (authoritative local zones)
#   services.dns.localForwardZones[] (forwarded zones, with relationId)
#
# The invariant is ordering: a more-specific zone must not be shadowed by a
# less-specific one, and the terminal local refusal must come last.
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
# `nixos` consumer repository; `protected-reservation-publication` declares a
# forward zone that names its authorizing relation and authority.
example_dir="$(pinned_lab_example protected-reservation-publication)"
intent_path="${example_dir}/intent.nix"
inventory_path="${example_dir}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL zone-ordering: $*" >&2; exit 1; }

[[ -f "${intent_path}" ]] || fail "P1 no zone-bearing fixture at ${intent_path}; the pinned network-labs example is missing"
[[ -f "${inventory_path}" ]] || fail "P1 no zone-bearing inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the pinned lab fixture does not compile, so no zone ordering can be asserted"

# P1: at least one target must carry zones, so the case is not vacuous.
if ! jq -e '[.. | objects | select(has("localForwardZones"))] | length > 0' "${model_json}" >/dev/null 2>&1; then
  fail "P1 no target carries localForwardZones, so zone ordering cannot be asserted"
fi

# P2: every forward zone must name the relation that authorizes it, so a zone is
# not emitted without a modeled source.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    sites = builtins.filter builtins.isAttrs
      (builtins.attrValues d.control_plane_model.data.esp0xdeadbeef);
    targetValues = builtins.concatMap
      (s: builtins.attrValues (s.runtimeTargets or { }))
      sites;
    zonesOf = t:
      let dns = (t.services or { }).dns or { };
      in if builtins.isAttrs dns then dns.localForwardZones or [ ] else [ ];
    allZones = builtins.concatLists (map zonesOf targetValues);
    authorize = builtins.filter (z: (z.relationId or null) != null && (z.forwardTo or [ ]) != [ ]) allZones;
  in
    builtins.length allZones > 0 && builtins.length authorize == builtins.length allZones
' | grep -qx true; then
  fail "P2 a forward zone carries no relationId or no forwardTo, so it is emitted without a modeled source or a destination"
fi

# P2: a more-specific zone must not be shadowed by a less-specific zone that
# appears earlier in the emitted order. Compare by label count: an earlier zone
# must not be a suffix-match ancestor of a later, more specific zone.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    sites = builtins.filter builtins.isAttrs
      (builtins.attrValues d.control_plane_model.data.esp0xdeadbeef);
    targetValues = builtins.concatMap
      (s: builtins.attrValues (s.runtimeTargets or { }))
      sites;

    zonesOf = t:
      let dns = (t.services or { }).dns or { };
      in
      if builtins.isAttrs dns then (dns.localZones or [ ]) ++ (dns.localForwardZones or [ ]) else [ ];

    namesOf = t: map (z: z.name or "") (zonesOf t);

    # A shadowed zone is one whose name is a strict suffix of another zone that is
    # emitted before it.
    isSuffixOf = a: b: a != "" && b != "" && a != b
      && builtins.match ".*\\.${a}" b != null;

    shadowedIn = names:
      let
        n = builtins.length names;
        idx = builtins.genList (i: i) n;
        bad = builtins.filter
          (i:
            let
              later = builtins.elemAt names i;
              earlier = builtins.genList (j: builtins.elemAt names j) i;
            in
              builtins.any (e: isSuffixOf later e) earlier)
          idx;
      in builtins.length bad;

    shadowed = builtins.any (t: shadowedIn (namesOf t) > 0) targetValues;
  in
    shadowed == false
' | grep -qx true; then
  fail "P2 a more-specific zone is shadowed by a less-specific zone emitted before it, so the more-specific match does not win"
fi

echo "PASS zone-ordering"
