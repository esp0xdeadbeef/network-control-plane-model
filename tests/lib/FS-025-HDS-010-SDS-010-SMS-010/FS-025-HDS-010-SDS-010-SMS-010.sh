#!/usr/bin/env bash
# GAMP-ID: FS-025-HDS-010-SDS-010-SMS-010
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

# FS-025 classification at the emitting layer: every requirement-class failure
# must resolve to a render abort. This case exercises three distinct failure
# classes and requires each one to abort with its own stable code and release no
# artifact, rather than being silently dropped or collapsed into one outcome.
#
# Scope note: the `runtime-deny` mode is not observable here. CPM emits only
# `allow`/`accept` decisions; rendered denies are produced by the renderer's
# default-drop posture. This case therefore proves the render-abort class and
# its per-class discrimination, not the deny class.

declare -a codes=()

run_case() {
  local label="$1"
  local intent="$2"
  local out="${tmp_dir}/${label}.out"
  local err="${tmp_dir}/${label}.err"
  local rc

  set +e
  compile_paths "${intent}" "${inventory_source}" >"${out}" 2>"${err}"
  rc=$?
  set -e

  if ((rc == 0)); then
    echo "FAIL failure-mode-classification: failure class '${label}' produced a successful run" >&2
    exit 1
  fi

  if [[ -s "${out}" ]]; then
    echo "FAIL failure-mode-classification: failure class '${label}' released an artifact" >&2
    exit 1
  fi

  local code
  set +e
  code="$(grep -oE '"code":"E_[A-Z_]+"' "${err}" | head -1 | sed 's/"code":"//; s/"//')"
  if [[ -z "${code}" ]]; then
    code="$(grep -oE 'diagnostic\.[a-z0-9-]+' "${err}" | head -1)"
  fi
  set -e
  if [[ -z "${code}" ]]; then
    echo "FAIL failure-mode-classification: failure class '${label}' produced no stable E_* code" >&2
    cat "${err}" >&2
    exit 1
  fi
  codes+=("${code}")
}

# Class 1: a relation missing its endpoint selector.
empty_selector_intent="${tmp_dir}/intent-empty-selector.nix"
cat >"${empty_selector_intent}" <<EOF
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
run_case "empty-selector" "${empty_selector_intent}"

# Class 2: a site with no egress allow and no ingress authority.
no_egress_intent="${tmp_dir}/intent-no-egress.nix"
cat >"${no_egress_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      communicationContract = site.communicationContract // {
        relations = builtins.filter
          (rel: rel.id != "allow-tenants-to-wan")
          site.communicationContract.relations;
      };
    };
  };
}
EOF
run_case "no-egress" "${no_egress_intent}"

# Class 3: a service left without any allow relation, so it has no exposure class.
no_exposure_intent="${tmp_dir}/intent-no-exposure.nix"
cat >"${no_exposure_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      communicationContract = site.communicationContract // {
        relations = builtins.filter
          (rel: rel.id != "allow-tenants-to-site-dns")
          site.communicationContract.relations;
      };
    };
  };
}
EOF
run_case "no-exposure" "${no_exposure_intent}"

# The three classes resolved to their own codes: the classifier discriminates
# instead of collapsing every requirement-class failure into one outcome.
mapfile -t unique_codes < <(printf '%s\n' "${codes[@]}" | sort -u)
if ((${#unique_codes[@]} != ${#codes[@]})); then
  echo "FAIL failure-mode-classification: distinct failure classes collapsed to the same code (${codes[*]})" >&2
  exit 1
fi

# A conforming source still emits, so the abort class is specific to the
# non-conforming sources and does not mask ordinary emission.
compile_paths "${intent_path}" "${inventory_source}" >"${tmp_dir}/conforming.json"
if [[ ! -s "${tmp_dir}/conforming.json" ]]; then
  echo "FAIL failure-mode-classification: a conforming source released no artifact" >&2
  exit 1
fi

echo "PASS failure-mode-classification"
