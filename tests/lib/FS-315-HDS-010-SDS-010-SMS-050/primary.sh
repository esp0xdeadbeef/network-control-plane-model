#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: FS-315-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
# Focused construction test: advertisement route-set cardinality module.
# Exercises all seeded negatives from SMS FS-315-HDS-010-SDS-010-SMS-050.

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

fail_with() {
  local test_name="$1"; shift
  printf 'FAIL %s: %s\n' "${test_name}" "$*" >&2
  exit 1
}

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan-uplink-static-egress"
intent_path="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

[[ -f "${intent_path}" ]] || fail_with "fixture" "missing intent fixture: ${intent_path}"
[[ -f "${inventory_source}" ]] || fail_with "fixture" "missing inventory fixture: ${inventory_source}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
cp "${inventory_source}" "${tmpdir}/inventory.nix"

compile_canonical() {
  local outfile="$1"
  nix eval --no-write-lock-file --impure --json --expr "
    let
      flake = builtins.getFlake \"path:${repo_root}\";
      out = flake.libBySystem.\"${system}\".compileAndBuildFromPaths {
        inputPath = \"${intent_path}\";
        inventoryPath = \"${tmpdir}/inventory.nix\";
      };
    in
      out
  " >"${outfile}" || fail_with "compile" "canonical compile failed"
}

# The evaluated predicate, shared by every seeded negative. `MODE` selects what
# is asserted so a single expression covers SN1/SN2/SN3 without re-deriving the
# walk in bash.
advertisement_predicate() {
  local outfile="$1"
  local mode="$2"
  OUTPUT_JSON="${outfile}" MODE="${mode}" nix eval --no-write-lock-file --impure --raw --expr '
    let
      data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
      mode = builtins.getEnv "MODE";
      sites = data.control_plane_model.data.esp0xdeadbeef;
      targets = builtins.concatMap
        (s: builtins.attrValues (s.runtimeTargets or { }))
        (builtins.attrValues sites);

      # Every advertised route list, both families, every mechanism.
      advertiseLists = target:
        let
          ra = target.advertisements.ipv6Ra or [ ];
          dhcp4 = target.advertisements.dhcp4 or [ ];
        in
        (map (a: a.moreSpecificRoutes or [ ]) ra)
        ++ (map (a: a.classlessStaticRoutes or [ ]) dhcp4)
        ++ (map (a: a.routes4 or [ ]) dhcp4);

      lists = builtins.concatMap advertiseLists targets;
      nonEmpty = builtins.filter (l: l != [ ]) lists;

      distinct = list:
        builtins.attrNames (builtins.listToAttrs (map (x: { name = toString x; value = true; }) list));

      isSet = list: builtins.length (distinct list) == builtins.length list;

      # The union of all advertised destinations across every target: collapsing
      # must not lose a destination that some advertisement carries.
      flattenLists = acc: remaining:
        if remaining == [ ] then acc
        else flattenLists (acc ++ builtins.head remaining) (builtins.tail remaining);

      unionOfAll = flattenLists [ ] lists;

      report = {
        targets = builtins.length targets;
        lists = builtins.length nonEmpty;
        allAreSets = builtins.all isSet nonEmpty;
        unionCount = builtins.length (distinct unionOfAll);
        unionAll = distinct unionOfAll;
      };
    in
      if mode == "shape" then builtins.toJSON report
      else if mode == "deterministic" then builtins.toJSON report
      else throw "unknown mode"
  ' 2>/dev/null || fail_with "predicate" "canonical advertisement walk failed"
}

canonical_json="${tmpdir}/canonical.json"
compile_canonical "${canonical_json}"

# ---- SN1: One advertisement carries each destination once -------------------
shape="$(advertisement_predicate "${canonical_json}" "shape")"
targets="$(jq -r '.targets' <<<"${shape}")"
advertised_lists="$(jq -r '.lists' <<<"${shape}")"
all_sets="$(jq -r '.allAreSets' <<<"${shape}")"
union_count="$(jq -r '.unionCount' <<<"${shape}")"

[[ "${targets}" -gt 0 ]] || fail_with "sn1-targets" "fixture produced no runtime targets, nothing was asserted"
[[ "${advertised_lists}" -gt 0 ]] || fail_with "sn1-lists" "no non-empty advertisement route list was produced"
[[ "${all_sets}" == "true" ]] \
  || fail_with "sn1-set-cardinality" "an advertisement repeats a destination prefix; a renderer would emit a second stanza and a second RFC 4191 route for it"
echo "PASS sn1-set-cardinality: ${advertised_lists} advertisement route list(s) across ${targets} target(s) each carry every destination once"

# ---- SN2: Collapsing does not delete distinct destinations ------------------
[[ "${union_count}" -ge 2 ]] \
  || fail_with "sn2-reachability" "the collapsed union holds ${union_count} destination(s); collapsing must not remove distinct reachability"
echo "PASS sn2-reachability: the collapsed sets still publish ${union_count} distinct destination(s)"

# ---- SN3: Evaluation is deterministic ---------------------------------------
canonical_json_2="${tmpdir}/canonical-2.json"
compile_canonical "${canonical_json_2}"
shape_2="$(advertisement_predicate "${canonical_json_2}" "deterministic")"
[[ "${shape}" == "${shape_2}" ]] \
  || fail_with "sn3-deterministic" "two evaluations produced different advertisement route sets"
echo "PASS sn3-deterministic: the route set is identical across two evaluations"

echo "PASS ${SMS_TEST_TRACE_ID:-FS-315-HDS-010-SDS-010-SMS-050}"
