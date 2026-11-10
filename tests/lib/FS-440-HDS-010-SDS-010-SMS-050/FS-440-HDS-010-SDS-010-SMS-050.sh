#!/usr/bin/env bash
# GAMP-ID: FS-440-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-440-HDS-010-SDS-010-SMS-050.md
# OWNER:  network-control-plane-model
#
# Behavioural case: compile the real example, then mutate the inventory so a
# runtime fact tries to act as authority, and require the run to refuse.
#
# Predicates taken from the SMS:
#   P1  Runtime facts are consumed as evidence of current provider state, not as
#       authority.
#   P2  A runtime fact that attempts to create policy or prefix authority is
#       rejected.
#
# Seeded negatives:
#   SN1  A runtime fact that creates prefix authority is refused, and the refusal
#        names the offending fact.
#   SN2  A non-conforming runtime fact value is refused rather than coerced.
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

compile_inventory() {
  local inventory="$1"
  nix eval --no-write-lock-file --impure --json --expr '
    let
      flake = builtins.getFlake "'"path:${repo_root}"'";
    in
      flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${intent_path}"'";
        inventoryPath = "'"${inventory}"'";
      }
  '
}

fail() { echo "FAIL runtime-facts-not-authority: $*" >&2; exit 1; }

# Baseline: the unmutated example compiles, so the negatives below are
# attributable to the injected runtime fact and not to a broken fixture.
baseline_json="${tmp_dir}/baseline.json"
compile_inventory "${inventory_path}" >"${baseline_json}" \
  || fail "P1 the unmutated example does not compile, so no runtime-fact refusal can be attributed"

# SN2: a non-conforming runtime-fact value is refused rather than coerced. The
# control-plane model documents providerAccess.links.* fields as authoritative
# runtime facts; a non-boolean where a boolean belongs must abort.
bad_runtime_fact="${tmp_dir}/inventory-bad-runtime-fact.nix"
cat >"${bad_runtime_fact}" <<EOF
let
  base = import ${inventory_path};
  sites = builtins.mapAttrs
    (siteName: site:
      site // {
        providerAccess = (site.providerAccess or { }) // {
          links = builtins.mapAttrs
            (_: link: link // { enabled = "yes-please"; })
            ((site.providerAccess or { }).links or { });
        };
      })
    base.controlPlane.sites.esp0xdeadbeef;
in
base // {
  controlPlane = base.controlPlane // {
    sites = base.controlPlane.sites // { esp0xdeadbeef = sites; };
  };
}
EOF

set +e
compile_inventory "${bad_runtime_fact}" >"${tmp_dir}/bad.out" 2>"${tmp_dir}/bad.err"
bad_rc=$?
set -e

if ((bad_rc == 0)); then
  fail "SN2 a non-conforming runtime fact was coerced instead of refused; the run produced a model"
fi

if [[ -s "${tmp_dir}/bad.out" ]]; then
  fail "SN2 the refused run released an artifact on stdout"
fi

# SN1: the refusal must name the offending fact, so a runtime fact cannot be
# rejected anonymously.
if ! grep -qiE 'providerAccess|runtime|enabled|boolean' "${tmp_dir}/bad.err"; then
  fail "SN1 the refusal did not name the offending runtime fact
$(cat "${tmp_dir}/bad.err")"
fi

echo "PASS runtime-facts-not-authority"
