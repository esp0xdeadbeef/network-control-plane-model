#!/usr/bin/env bash
# GAMP-ID: FS-381-HDS-010-SDS-010-SMS-010
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

baseline_json="${tmp_dir}/baseline.json"
compile_paths "${intent_path}" "${inventory_source}" >"${baseline_json}"

# FS-381: a permitted exit path must be complete at every modeled forwarding
# hop. CPM exposes the per-target capability that decides whether a hop carries
# the path onward: an upstream-selector claims `selectsUpstream`, and the core
# that owns the uplink claims `exitsSite`. A permitted external path whose hop
# sequence contains no such terminal capability is presented as reachable while
# nothing on it claims the exit, which is the incomplete permitted-exit path
# this item forbids.
if ! BASELINE_JSON="${baseline_json}" nix eval --no-write-lock-file --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "BASELINE_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    targets = site.runtimeTargets;
    authorityOf = n: targets.${n}.routingAuthority;
    claimsExit = n:
      let a = authorityOf n; in a.exitsSite || a.selectsUpstream;
    externalPaths = builtins.filter
      (p: (p.destination.kind or null) == "external" && p.action == "allow")
      site.trafficPaths;
    hopsClaimingExit = p:
      builtins.filter (
        nodeName:
        let
          targetName = "esp0xdeadbeef-site-a-" + nodeName;
        in
          targets ? "${targetName}" && claimsExit targetName
      ) p.nodePath;
    everyPathHasTerminalExit = builtins.all
      (p: builtins.length (hopsClaimingExit p) > 0)
      externalPaths;
    # The terminal hop must be the last hop: an exit claimed only mid-path
    # leaves the remaining hops without the path onward.
    exitsAreTerminal = builtins.all (
      p:
      let
        claimed = hopsClaimingExit p;
        lastHop = builtins.elemAt p.nodePath (builtins.length p.nodePath - 1);
      in
        builtins.elem lastHop claimed
    ) externalPaths;
  in
    builtins.length externalPaths > 0
    && everyPathHasTerminalExit
    && exitsAreTerminal
' | grep -qx true; then
  echo "FAIL permitted-exit-path-completeness: a permitted external path has no terminal hop claiming the exit, or its exit claim is not the last hop" >&2
  exit 1
fi

# SN1: pinning the exit to an unmodeled scope must not yield a path that claims
# the exit. The compiler must not resolve an unknown exit to a default core.
unmodeled_exit_intent="${tmp_dir}/intent-unmodeled-exit.nix"
cat >"${unmodeled_exit_intent}" <<EOF
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

if compile_paths "${unmodeled_exit_intent}" "${inventory_source}" \
  >"${tmp_dir}/unmodeled.out" 2>"${tmp_dir}/unmodeled.err"; then
  if ! UNMODELED_JSON="${tmp_dir}/unmodeled.out" nix eval --no-write-lock-file --impure --expr '
    let
      data = builtins.fromJSON (builtins.readFile (builtins.getEnv "UNMODELED_JSON"));
      site = data.control_plane_model.data.esp0xdeadbeef."site-a";
      targets = site.runtimeTargets;
      authorityOf = n: targets.${n}.routingAuthority;
      wanPath = builtins.head (
        builtins.filter (p: p.relationId == "allow-tenants-to-wan") site.trafficPaths
      );
      terminal = builtins.elemAt wanPath.nodePath (builtins.length wanPath.nodePath - 1);
      terminalTarget = "esp0xdeadbeef-site-a-" + terminal;
    in
      targets ? "${terminalTarget}" && (authorityOf terminalTarget).exitsSite
  ' | grep -qx true; then
    echo "FAIL permitted-exit-path-completeness: a path pinned to an unmodeled exit scope was accepted and terminated at a node that no modeled scope owns" >&2
    exit 1
  fi
fi

echo "PASS permitted-exit-path-completeness"
