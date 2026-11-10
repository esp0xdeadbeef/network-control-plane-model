#!/usr/bin/env bash
# GAMP-ID: FS-381-HDS-010-SDS-010-SMS-040
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

# FS-381 requires that a permitted-exit path which cannot be completed raises a
# render abort naming the source scope, the requiring fact, the incomplete hop,
# and the missing next hop, and that no artifact presents the scope as having
# exit reachability while the path is incomplete.
#
# The incomplete case under test: the exit is pinned to a scope that no modeled
# topology node owns. A complete path cannot be built to an exit that does not
# exist, so the run must abort. Emitting a path that terminates at the unmodeled
# name is the silent-omission defect.

incomplete_intent="${tmp_dir}/intent-incomplete-exit.nix"
cat >"${incomplete_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
  pinExit = rel:
    if rel.id == "allow-tenants-to-wan"
    then rel // { to = { kind = "external"; scope = "does-not-exist"; }; }
    else rel;
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      communicationContract = site.communicationContract // {
        relations = map pinExit site.communicationContract.relations;
      };
    };
  };
}
EOF

set +e
compile_paths "${incomplete_intent}" "${inventory_source}" \
  >"${tmp_dir}/incomplete.out" 2>"${tmp_dir}/incomplete.err"
rc=$?
set -e

if ((rc == 0)); then
  # The run succeeded. It is still conforming only if it did not present the
  # scope as having a complete exit path to an exit that does not exist.
  if ! INCOMPLETE_JSON="${tmp_dir}/incomplete.out" nix eval --no-write-lock-file --impure --expr '
    let
      data = builtins.fromJSON (builtins.readFile (builtins.getEnv "INCOMPLETE_JSON"));
      site = data.control_plane_model.data.esp0xdeadbeef."site-a";
      targets = site.runtimeTargets;
      wanPath = builtins.head (
        builtins.filter (p: p.relationId == "allow-tenants-to-wan") site.trafficPaths
      );
      terminal = builtins.elemAt wanPath.nodePath (builtins.length wanPath.nodePath - 1);
      terminalTarget = "esp0xdeadbeef-site-a-" + terminal;
    in
      targets ? "${terminalTarget}"
  ' | grep -qx true; then
    echo "FAIL incomplete-path-diagnostic: the incomplete permitted-exit path was emitted with a terminal hop that no modeled scope owns, and no abort named the hop or the missing next hop" >&2
    exit 1
  fi
  echo "FAIL incomplete-path-diagnostic: an uncompletable permitted-exit path produced a successful run without an abort" >&2
  exit 1
fi

# The abort must name the four required facts. Check for the source scope, the
# requiring fact, the incomplete hop, and the missing next hop.
missing=""
grep -qiE 'scope|site'        "${tmp_dir}/incomplete.err" || missing="${missing} source-scope"
grep -qiE 'relation|permission|selection' "${tmp_dir}/incomplete.err" || missing="${missing} requiring-fact"
grep -qiE 'hop|node|table'    "${tmp_dir}/incomplete.err" || missing="${missing} incomplete-hop"
grep -qiE 'next.?hop|via|gateway|missing' "${tmp_dir}/incomplete.err" || missing="${missing} missing-next-hop"

if [[ -n "${missing}" ]]; then
  echo "FAIL incomplete-path-diagnostic: the abort did not name:${missing}" >&2
  cat "${tmp_dir}/incomplete.err" >&2
  exit 1
fi

# The item must be attributed to FS-381 and not to the FS-481 behavior item.
if grep -q 'FS-481' "${tmp_dir}/incomplete.err" && ! grep -q 'FS-381' "${tmp_dir}/incomplete.err"; then
  echo "FAIL incomplete-path-diagnostic: the incomplete path was attributed to FS-481 instead of FS-381" >&2
  exit 1
fi

echo "PASS incomplete-path-diagnostic"
