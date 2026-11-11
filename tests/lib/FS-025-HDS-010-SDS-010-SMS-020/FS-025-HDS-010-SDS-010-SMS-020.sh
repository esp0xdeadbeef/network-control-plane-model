#!/usr/bin/env bash
# GAMP-ID: FS-025-HDS-010-SDS-010-SMS-020
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

# SN1: a non-conforming relation aborts the run before any artifact is released.
# FS-025 requires that a refusal to emit leaves no artifact and reports the
# scope, the requirement, and the missing or conflicting fact.
broken_intent="${tmp_dir}/intent-broken-relation.nix"
cat >"${broken_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      communicationContract = site.communicationContract // {
        relations = [ { action = "allow"; id = "broken"; } ];
      };
    };
  };
}
EOF

set +e
compile_paths "${broken_intent}" "${inventory_source}" \
  >"${tmp_dir}/broken.out" 2>"${tmp_dir}/broken.err"
broken_rc=$?
set -e

if ((broken_rc == 0)); then
  echo "FAIL render-abort-enforcement: a non-conforming relation contract produced a successful run" >&2
  exit 1
fi

# The abort releases no artifact: stdout carries no emitted model.
if [[ -s "${tmp_dir}/broken.out" ]]; then
  echo "FAIL render-abort-enforcement: the aborted run released artifact bytes on stdout" >&2
  exit 1
fi

# The abort names the scope, the requirement, and the conflicting fact, and it
# carries a stable code rather than a bare failure.
if ! grep -q '"code":"E_[A-Z_]*"' "${tmp_dir}/broken.err"; then
  echo "FAIL render-abort-enforcement: the abort carried no stable E_* code" >&2
  cat "${tmp_dir}/broken.err" >&2
  exit 1
fi

if ! grep -q '"site":"esp0xdeadbeef.site-a"' "${tmp_dir}/broken.err"; then
  echo "FAIL render-abort-enforcement: the abort did not name the affected scope" >&2
  exit 1
fi

if ! grep -q '"path":\[' "${tmp_dir}/broken.err"; then
  echo "FAIL render-abort-enforcement: the abort did not name the source path of the conflicting fact" >&2
  exit 1
fi

# SN2: the abort is not convertible into a successful run by a downstream
# consumer. A second compile of the same bad source must fail identically, so a
# stale artifact cannot be mistaken for the current run's output.
set +e
compile_paths "${broken_intent}" "${inventory_source}" \
  >"${tmp_dir}/broken-again.out" 2>"${tmp_dir}/broken-again.err"
again_rc=$?
set -e

if ((again_rc == 0)); then
  echo "FAIL render-abort-enforcement: an aborted run became successful on re-run" >&2
  exit 1
fi

# Compare the diagnostic record, not Nix's incidental stack trace. The trace
# embeds the /nix/store/<hash>-source path of the flake copy, and Nix re-copies
# a dirty working tree under a new hash whenever anything in it changed between
# the two evaluations — which concurrent CI test jobs routinely cause. Those
# store paths are not part of the diagnostic and must not decide whether the
# abort is reproducible; the structured `E_*` record is.
extract_diagnostic() {
  # The diagnostic is the emitted failure record carrying a stable E_* code.
  grep -o '{"code":"E_[^"]*"[^}]*}' "$1" | tail -1
}

diagnostic_first="$(extract_diagnostic "${tmp_dir}/broken.err")"
diagnostic_again="$(extract_diagnostic "${tmp_dir}/broken-again.err")"

if [[ -z "${diagnostic_first}" || -z "${diagnostic_again}" ]]; then
  echo "FAIL render-abort-enforcement: an aborted run carried no stable E_* diagnostic record to compare" >&2
  cat "${tmp_dir}/broken.err" "${tmp_dir}/broken-again.err" >&2
  exit 1
fi

if [[ "${diagnostic_first}" != "${diagnostic_again}" ]]; then
  echo "FAIL render-abort-enforcement: the abort diagnostic is not reproducible across runs" >&2
  printf 'first: %s\nagain: %s\n' "${diagnostic_first}" "${diagnostic_again}" >&2
  exit 1
fi

# SN3: a conforming source still emits an artifact, so the abort is specific to
# the non-conforming source and does not mask ordinary emission.
conforming_json="${tmp_dir}/conforming.json"
compile_paths "${intent_path}" "${inventory_source}" >"${conforming_json}"

if [[ ! -s "${conforming_json}" ]]; then
  echo "FAIL render-abort-enforcement: a conforming source released no artifact" >&2
  exit 1
fi

if ! jq -e '.control_plane_model.data.esp0xdeadbeef."site-a".trafficPaths | length > 0' \
  "${conforming_json}" >/dev/null; then
  echo "FAIL render-abort-enforcement: the conforming artifact carries no model" >&2
  exit 1
fi

echo "PASS render-abort-enforcement"
