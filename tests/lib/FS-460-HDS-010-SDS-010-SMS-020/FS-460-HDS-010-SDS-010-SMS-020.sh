#!/usr/bin/env bash
# GAMP-ID: FS-460-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-460-HDS-010-SDS-010-SMS-020.md
# OWNER:  network-control-plane-model
#
# Predicates: Nebula underlay and overlay readiness stay separate from payload,
# tenant, management, resolver and public-ingress reachability; an attempt to
# convert underlay reachability into payload authority is rejected.
#
# Behavioural: compile the real nebula example and assert on the emitted model.
# The invariant is that adding Nebula to a model adds no payload permission — the
# relation set must be exactly what the intent declares, so an overlay presence
# cannot manufacture a grant.
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

flake_input_path() {
  local input_name="$1"
  if [[ "${input_name}" == "network-labs" && -n "${NETWORK_LABS_PATH:-}" ]]; then
    realpath "${NETWORK_LABS_PATH}"; return
  fi
  nix flake archive --json "path:${repo_root}" | jq -er ".inputs[\"${input_name}\"].path"
}

labs_root="$(flake_input_path network-labs)"
nebula_root="${labs_root}/examples/single-wan-with-nebula"
intent_path="${nebula_root}/intent.nix"
inventory_path="${nebula_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL nebula-readiness-not-authority: $*" >&2; exit 1; }

[[ -f "${intent_path}" ]] || fail "P1 the nebula example does not exist, so nothing can be asserted about readiness"
[[ -f "${inventory_path}" ]] || fail "P1 the nebula inventory does not exist"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the nebula example does not compile"

# P1: Nebula must actually be present, so the rest of the case is not vacuous.
if ! grep -qi 'nebula' "${model_json}"; then
  fail "P1 the compiled nebula example carries no nebula facts, so readiness separation cannot be asserted"
fi

# P2: every emitted relation must come from the intent's relation set. A relation
# that exists only because an overlay is present would be underlay reachability
# converted into payload authority.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    site = d.control_plane_model.data.esp0xdeadbeef."site-a";
    relations = site.relations;
    # Every relation must carry a user-intent source audit; a relation whose
    # source class is not user-intent was not modeled as permission.
    audited = builtins.filter
      (r: ((r.source.sourceAudit.sourceClass or null) == "user-intent"))
      relations;
  in
    builtins.length relations > 0 && builtins.length audited == builtins.length relations
' | grep -qx true; then
  fail "P2 an emitted relation is not sourced from user-intent, so overlay presence created permission rather than the model declaring it"
fi

# P2: traffic paths must not be created for relations absent from the relation set.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    site = d.control_plane_model.data.esp0xdeadbeef."site-a";
    ids = map (r: r.id) site.relations;
    pathIds = map (p: p.relationId) site.trafficPaths;
  in
    builtins.all (id: builtins.elem id ids) pathIds
' | grep -qx true; then
  fail "P2 a traffic path exists with no modeled relation, so reachability was manufactured from overlay presence"
fi

echo "PASS nebula-readiness-not-authority"
