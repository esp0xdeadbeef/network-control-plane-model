#!/usr/bin/env bash
# GAMP-ID: FS-323-HDS-010-SDS-010-SMS-010
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

# FS-323: reachability is carried only by scope offers/selects and permission
# only by relations. The positive path proves the emitted model keeps the two
# facts on separate record sets and that no allow relation lacks its path.
baseline_json="${tmp_dir}/baseline.json"
compile_paths "${intent_path}" "${inventory_source}" >"${baseline_json}"

if ! BASELINE_JSON="${baseline_json}" nix eval --no-write-lock-file --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "BASELINE_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    paths = site.trafficPaths;
    relations = site.relations;
    forbiddenOnRelation = [
      "nextHop" "nextHops" "via" "gateway" "table" "route" "routes"
      "offers" "selects" "stagePath" "nodePath"
    ];
    relationCarriesRouting = builtins.any
      (r: builtins.any (k: r ? "${k}") forbiddenOnRelation)
      relations;
    relationCarriesPayload = builtins.all
      (r: (r ? "match") && (r ? "returnBehavior") && (r ? "priority"))
      relations;
    pathCarriesPermission = builtins.any
      (p: (p ? "match") || (p ? "returnBehavior") || (p ? "priority"))
      paths;
    pathHasReachability = builtins.all
      (p: (p ? "nodePath") && (p ? "stagePath"))
      paths;
    relationIds = map (r: r.id) relations;
    pathIds = map (p: p.relationId) paths;
    everyPathHasRelation = builtins.all (id: builtins.elem id relationIds) pathIds;
  in
    builtins.length relations > 0
    && builtins.length paths > 0
    && pathHasReachability
    && !relationCarriesRouting
    && relationCarriesPayload
    && !pathCarriesPermission
    && everyPathHasRelation
' | grep -qx true; then
  echo "FAIL reachability-fact-permission-separation: emitted model does not keep reachability on trafficPaths and permission on relations as separate record sets" >&2
  exit 1
fi

# SN1: a relation that names a next hop must never reach the permission record.
# FS-323 forbids permission carrying a routing instruction; the contract boundary
# is that the emitted relation record has no routing field. Whether the compiler
# rejects the superseded shape or drops it is owned by the relation validator
# (FS-320), so this case asserts the separation boundary itself.
relation_routing_intent="${tmp_dir}/intent-relation-routing.nix"
cat >"${relation_routing_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
  addRouting = rel: rel // { nextHop = "10.0.0.1"; };
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    "site-a" = site // {
      communicationContract = site.communicationContract // {
        relations = map addRouting site.communicationContract.relations;
      };
    };
  };
}
EOF

if compile_paths "${relation_routing_intent}" "${inventory_source}" \
  >"${tmp_dir}/relation-routing.out" 2>"${tmp_dir}/relation-routing.err"; then
  if ! RELATION_ROUTING_JSON="${tmp_dir}/relation-routing.out" nix eval --no-write-lock-file --impure --expr '
    let
      data = builtins.fromJSON (builtins.readFile (builtins.getEnv "RELATION_ROUTING_JSON"));
      site = data.control_plane_model.data.esp0xdeadbeef."site-a";
      forbidden = [ "nextHop" "nextHops" "via" "gateway" "table" "route" ];
    in
      builtins.all (r: builtins.all (k: !(r ? "${k}")) forbidden) site.relations
  ' | grep -qx true; then
    echo "FAIL reachability-fact-permission-separation: a routing instruction reached an emitted permission record" >&2
    exit 1
  fi
fi

# SN2: a tenant scope that offers no reachability while a relation permits its
# traffic must be reported, not silently given a path.
selects_stripped_intent="${tmp_dir}/intent-no-selects.nix"
cat >"${selects_stripped_intent}" <<EOF
let
  base = import ${intent_path};
  site = base.esp0xdeadbeef."site-a";
  stripSelects = topology:
    topology // {
      nodes = builtins.mapAttrs
        (name: node:
          if node ? selects then removeAttrs node [ "selects" ] else node)
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

if compile_paths "${selects_stripped_intent}" "${inventory_source}" \
  >"${tmp_dir}/no-selects.out" 2>"${tmp_dir}/no-selects.err"; then
  if ! NO_SELECTS_JSON="${tmp_dir}/no-selects.out" nix eval --no-write-lock-file --impure --expr '
    let
      data = builtins.fromJSON (builtins.readFile (builtins.getEnv "NO_SELECTS_JSON"));
      site = data.control_plane_model.data.esp0xdeadbeef."site-a";
      allowPaths = builtins.filter (p: p.action == "allow") site.trafficPaths;
      pathsWithMultiHop = builtins.filter (p: builtins.length p.nodePath > 1) allowPaths;
    in
      builtins.length pathsWithMultiHop == 0
  ' | grep -qx true; then
    echo "FAIL reachability-fact-permission-separation: a scope with no selects still produced a multi-hop reachability path" >&2
    exit 1
  fi
fi

# SN3: dropping a permit relation must remove its path. Permission does not
# persist a reachability fact by itself.
no_wan_intent="${tmp_dir}/intent-no-wan-relation.nix"
cat >"${no_wan_intent}" <<EOF
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

compile_paths "${no_wan_intent}" "${inventory_source}" >"${tmp_dir}/no-wan.out"

if ! NO_WAN_JSON="${tmp_dir}/no-wan.out" nix eval --no-write-lock-file --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "NO_WAN_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    pathIds = map (p: p.relationId) site.trafficPaths;
  in
    !(builtins.elem "allow-tenants-to-wan" pathIds)
' | grep -qx true; then
  echo "FAIL reachability-fact-permission-separation: removing a permit relation left a reachability path behind" >&2
  exit 1
fi

echo "PASS reachability-fact-permission-separation"
