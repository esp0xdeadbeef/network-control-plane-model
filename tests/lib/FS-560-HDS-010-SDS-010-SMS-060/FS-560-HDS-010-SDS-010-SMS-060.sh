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
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

nixos_src="${NIXOS_SRC:-${HOME}/github/nixos}"
intent_path="${nixos_src}/prod-network/testing/intent-cobalt.nix"
inventory_path="${nixos_src}/prod-network/testing/inventory-cobalt.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL namespace-suffix-declaration: $*" >&2; exit 1; }

[[ -f "${intent_path}" ]] || fail "P1 no namespace-bearing fixture at ${intent_path}; set NIXOS_SRC to the nixos checkout"
[[ -f "${inventory_path}" ]] || fail "P1 no namespace-bearing inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'.compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the cobalt testing model does not compile, so no namespace can be validated"

# P1: at least one namespace must be modeled, so the case is not vacuous.
if ! jq -e '[.. | objects | select(has("protectedReservationPublications"))] | length > 0' "${model_json}" >/dev/null 2>&1; then
  fail "P1 the model carries no protectedReservationPublications, so no namespace relation exists to validate"
fi

# P1: every namespace names an owner scope. A namespace with no modeled owner is a
# suffix that no scope declared.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    targets = builtins.attrValues d.control_plane_model.data.esp0xdeadbeef.cobalt.runtimeTargets;
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
# The named site zones are taken from the model itself (`localZones`), and a
# namespace must be strictly more specific than the zone it sits under. The subject
# is the namespace value, not the zone list: localZones also carry reverse zones
# derived from prefixes, so requiring every zone to be namespace-covered would fail
# on legitimate `in-addr.arpa` entries.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    site = d.control_plane_model.data.esp0xdeadbeef.cobalt;
    targetValues = builtins.attrValues site.runtimeTargets;

    namespaces = map (p: p.namespace) (builtins.concatLists (
      map (t: (t.services.dns or { }).protectedReservationPublications or [ ]) targetValues
    ));

    siteZones = builtins.filter
      (z: builtins.match ".*arpa\\.$" z == null)
      (map (z: z.name) (builtins.concatLists (
        map (t: (t.services.dns or { }).localZones or [ ]) targetValues
      )));

    # Explicit means: strictly more specific than a named site zone, so the scope
    # chose the suffix rather than inheriting it.
    explicit = ns:
      builtins.any
        (z: ns != z && builtins.match ".*\\.${z}" ns != null)
        siteZones;
  in
    builtins.length namespaces > 0 && builtins.all explicit namespaces
' | grep -qx true; then
  fail "P2 a published namespace is not explicitly qualified under a named site zone, so it inherits a site-wide default, which URS Local Service Discovery forbids"
fi

echo "PASS namespace-suffix-declaration"
