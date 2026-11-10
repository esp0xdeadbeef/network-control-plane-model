#!/usr/bin/env bash
# GAMP-ID: FS-025-HDS-010-SDS-010-SMS-030
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

# FS-025 requires that a reader can tell, for every failure item, whether it
# forbids emission, denies a flow, or only requires visibility. The diagnostic
# record must therefore carry the mode, not only a code and a message.
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
  echo "FAIL diagnostic-mode-declaration: the non-conforming source did not abort" >&2
  exit 1
fi

if ! grep -q '"code":"E_[A-Z_]*"' "${tmp_dir}/broken.err"; then
  echo "FAIL diagnostic-mode-declaration: the abort carried no stable E_* code" >&2
  exit 1
fi

# SN1: the failure record must declare its FS-025 mode.
if ! grep -qE '"(mode|failureMode)":"(render-abort|runtime-deny|visibility-only)"' \
  "${tmp_dir}/broken.err"; then
  echo "FAIL diagnostic-mode-declaration: the failure record declares no FS-025 mode (render-abort|runtime-deny|visibility-only); a reader cannot tell whether the condition forbids emission, denies a flow, or only requires visibility" >&2
  exit 1
fi

echo "PASS diagnostic-mode-declaration"
