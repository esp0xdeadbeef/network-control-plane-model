#!/usr/bin/env bash
# GAMP-ID: FS-323-HDS-010-SDS-010-SMS-020
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

# SN2: a scope that offers reachability but has no relation must not receive
# payload permission. FS-323 forbids deriving permission from reachability.
# Removing every relation leaves the topology and its offers/selects intact, so
# any emitted allow rule would be permission inferred from reachability.
no_relations_intent="${tmp_dir}/intent-no-relations.nix"
cat >"${no_relations_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      communicationContract = site.communicationContract // {
        relations = [ ];
      };
    };
  };
}
EOF

if compile_paths "${no_relations_intent}" "${inventory_source}" \
  >"${tmp_dir}/no-relations.out" 2>"${tmp_dir}/no-relations.err"; then
  if ! NO_RELATIONS_JSON="${tmp_dir}/no-relations.out" nix eval --no-write-lock-file --impure --expr '
    let
      data = builtins.fromJSON (builtins.readFile (builtins.getEnv "NO_RELATIONS_JSON"));
      site = data.control_plane_model.data.esp0xdeadbeef."site-a";
      allowPaths = builtins.filter (p: p.action == "allow") site.trafficPaths;
    in
      site.relations == [ ] && builtins.length allowPaths == 0
  ' | grep -qx true; then
    echo "FAIL permission-fact-validator: permission was derived from reachability with no modeled relation" >&2
    exit 1
  fi
fi

# SN3: an explicit deny relation must not be converted into a grant by the
# presence of an offered prefix.
deny_intent="${tmp_dir}/intent-deny.nix"
cat >"${deny_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
  toDeny = rel:
    if rel.id == "allow-tenants-to-wan"
    then rel // { action = "deny"; }
    else rel;
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      communicationContract = site.communicationContract // {
        relations = map toDeny site.communicationContract.relations;
      };
    };
  };
}
EOF

if compile_paths "${deny_intent}" "${inventory_source}" \
  >"${tmp_dir}/deny.out" 2>"${tmp_dir}/deny.err"; then
  if ! DENY_JSON="${tmp_dir}/deny.out" nix eval --no-write-lock-file --impure --expr '
    let
      data = builtins.fromJSON (builtins.readFile (builtins.getEnv "DENY_JSON"));
      site = data.control_plane_model.data.esp0xdeadbeef."site-a";
      wanPath = builtins.filter (p: p.relationId == "allow-tenants-to-wan") site.trafficPaths;
      wanRelation = builtins.filter (r: r.id == "allow-tenants-to-wan") site.relations;
    in
      builtins.all (r: r.action == "deny") wanRelation
      && builtins.all (p: p.action == "deny") wanPath
  ' | grep -qx true; then
    echo "FAIL permission-fact-validator: a deny relation was converted into an allow by the offered prefix" >&2
    exit 1
  fi
fi

# Positive: the relation stays the sole source of payload permission shape. The
# emitted allow relation carries the modeled match and return behavior, and no
# path record carries them.
baseline_json="${tmp_dir}/baseline.json"
compile_paths "${intent_path}" "${inventory_source}" >"${baseline_json}"

if ! BASELINE_JSON="${baseline_json}" nix eval --no-write-lock-file --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "BASELINE_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    allowRelations = builtins.filter (r: r.action == "allow") site.relations;
  in
    builtins.length allowRelations > 0
    && builtins.all (r: r ? "match" && r ? "returnBehavior") allowRelations
    && builtins.all (p: !(p ? "match") && !(p ? "returnBehavior")) site.trafficPaths
' | grep -qx true; then
  echo "FAIL permission-fact-validator: payload permission shape is not carried solely by relations" >&2
  exit 1
fi

echo "PASS permission-fact-validator"
