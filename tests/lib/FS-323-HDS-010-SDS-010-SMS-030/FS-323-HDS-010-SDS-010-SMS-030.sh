#!/usr/bin/env bash
# GAMP-ID: FS-323-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

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

flake_input_path() {
  local input_name="$1"
  if [[ "${input_name}" == "network-labs" && -n "${NETWORK_LABS_PATH:-}" ]]; then
    realpath "${NETWORK_LABS_PATH}"
    return
  fi
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan"
intent_path="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

compile_paths() {
  local intent="$1"
  local inventory="$2"
  nix eval --no-write-lock-file --impure --json --expr '
    let
      flake = builtins.getFlake "'"path:${repo_root}"'";
    in
      flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${intent}"'";
        inventoryPath = "'"${inventory}"'";
      }
  '
}

# FS-323: when exactly one of the two facts is present for a tuple, the model
# must report which one is missing against the layer that owns it, rather than
# reporting a single combined outcome or resolving the asymmetry with a default.
#
# The one-sided case under test: a relation permits reachability to an exit while
# the scope carries no selection. The report must name reachability as the
# missing fact. A model that instead emits a complete path has synthesised the
# missing fact.
one_sided_intent="${tmp_dir}/intent-one-sided.nix"
cat >"${one_sided_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
  stripSelects = topology: topology // {
    nodes = builtins.mapAttrs
      (name: node: if node ? selects then removeAttrs node [ "selects" ] else node)
      topology.nodes;
  };
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      topology = stripSelects site.topology;
    };
  };
}
EOF

set +e
compile_paths "${one_sided_intent}" "${inventory_source}" \
  >"${tmp_dir}/one-sided.out" 2>"${tmp_dir}/one-sided.err"
rc=$?
set -e

if ((rc != 0)); then
  # A loud report of the missing reachability fact satisfies this item, as long
  # as it names reachability rather than permission.
  if grep -qiE 'selects|reachab' "${tmp_dir}/one-sided.err"; then
    echo "PASS one-sided-fact-diagnostic"
    exit 0
  fi
  echo "FAIL one-sided-fact-diagnostic: the run aborted without naming the missing reachability fact" >&2
  cat "${tmp_dir}/one-sided.err" >&2
  exit 1
fi

# The run succeeded. It is only conforming if it reports the missing fact.
if ! grep -qiE 'missing.{0,40}reachab|reachab.{0,40}missing|one-sided|missing.{0,20}selects' \
  "${tmp_dir}/one-sided.err"; then
  echo "FAIL one-sided-fact-diagnostic: a scope with no selection and a permitting relation produced no diagnostic naming the missing reachability fact; the missing fact was synthesised instead of reported" >&2
  exit 1
fi

echo "PASS one-sided-fact-diagnostic"
