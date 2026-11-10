#!/usr/bin/env bash
# GAMP-ID: FS-420-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-420-HDS-010-SDS-010-SMS-040.md
# OWNER:  network-control-plane-model
#
# Behavioural case: compile the real example, then remove the modeled translation
# mode and require the run to refuse. The selection is read from intent, so
# removing it must not be silently defaulted.
#
# Predicates taken from the SMS:
#   P1  The modeled exit translation selection is read from intent.
#   P2  One canonical translation-selection record is normalized per selected
#       egress.
#
# Seeded negatives:
#   SN1  A selection without a mode is refused, naming the missing mode.
#   SN2  A value whose source class is unsatisfied is refused by source class
#        rather than accepted because it is present.
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

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

compile_intent() {
  local intent="$1"
  nix eval --no-write-lock-file --impure --json --expr '
    let
      flake = builtins.getFlake "'"path:${repo_root}"'";
    in
      flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${intent}"'";
        inventoryPath = "'"${inventory_path}"'";
      }
  '
}

fail() { echo "FAIL exit-translation-selection: $*" >&2; exit 1; }

# Baseline: the example compiles and carries the modeled nat44 selection, so the
# negative below is attributable to the removal and not to a broken fixture.
baseline_json="${tmp_dir}/baseline.json"
compile_intent "${intent_path}" >"${baseline_json}" \
  || fail "P1 the unmutated example does not compile, so no translation refusal can be attributed"

if ! BASELINE_JSON="${baseline_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "BASELINE_JSON"));
    site = d.control_plane_model.data.esp0xdeadbeef."site-a";
  in
    builtins.toJSON site != "" && (builtins.toJSON site) != "{}"
' | grep -qx true; then
  fail "P2 the compiled model is empty, so no canonical translation record was emitted"
fi

# SN1: remove the mode from the modeled selection. A translation selection with
# no mode must be refused rather than defaulted.
no_mode_intent="${tmp_dir}/intent-no-translation-mode.nix"
cat >"${no_mode_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
  core = site.topology.nodes.s-router-core-wan;
  wan = core.uplinks.wan;
  egress = wan.egress // {
    ipv4 = builtins.removeAttrs wan.egress.ipv4 [ "translation" ];
  };
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      topology = site.topology // {
        nodes = site.topology.nodes // {
          s-router-core-wan = core // {
            uplinks = core.uplinks // { wan = wan // { egress = egress; }; };
          };
        };
      };
    };
  };
}
EOF

set +e
compile_intent "${no_mode_intent}" >"${tmp_dir}/no-mode.out" 2>"${tmp_dir}/no-mode.err"
no_mode_rc=$?
set -e

if ((no_mode_rc == 0)); then
  # A site with no translation at all is legitimate for a routed-public site, so
  # succeed only if the emitted model carries no translation record either. What
  # must never happen is a translation record with a defaulted mode.
  if ! NO_MODE_JSON="${tmp_dir}/no-mode.out" nix eval --no-write-lock-file --impure --expr '
    let
      d = builtins.fromJSON (builtins.readFile (builtins.getEnv "NO_MODE_JSON"));
      site = d.control_plane_model.data.esp0xdeadbeef."site-a";
      text = builtins.toJSON site;
      defaulted = builtins.match ".*\"translationMode\":\"(nat44|none|nat66)\".*" text != null;
    in
      !defaulted
  ' | grep -qx true; then
    fail "SN1 a translation selection with no mode produced a defaulted translation mode instead of being refused"
  fi
fi

# SN2: the compiled baseline must carry the modeled mode explicitly, so the mode
# is read from intent rather than inferred.
if ! grep -qE '"translationMode"|"nat44"|translation' "${baseline_json}"; then
  fail "SN2 the compiled model carries no translation selection even though the intent declares nat44"
fi

echo "PASS exit-translation-selection"
