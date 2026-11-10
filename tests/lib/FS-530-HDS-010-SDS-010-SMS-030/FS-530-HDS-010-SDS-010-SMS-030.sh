#!/usr/bin/env bash
# GAMP-ID: FS-530-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-530-HDS-010-SDS-010-SMS-030.md
# OWNER:  network-control-plane-model
#
# Predicates: resolver-owning node loopback behaviour is preserved separately from
# client recursion authority, and loopback resolver behaviour grants no unrelated
# client recursion.
#
# Behavioural: compile the real example and check the emitted model, not the
# source text. CPM carries a per-target `effectiveRuntimeRealization.loopback`
# address; the invariant is that a client's advertised resolver is never another
# scope's loopback address, because that would be loopback behaviour granting
# unrelated client recursion.
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

example_root="$(flake_input_path network-labs)/examples/single-wan"
intent_path="${example_root}/intent.nix"
inventory_path="${example_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL loopback-resolver-separation: $*" >&2; exit 1; }

compile_paths() {
  nix eval --no-write-lock-file --impure --json --expr '
    let
      flake = builtins.getFlake "'"path:${repo_root}"'";
    in
      flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${intent_path}"'";
        inventoryPath = "'"${inventory_path}"'";
      }
  '
}

model_json="${tmp_dir}/model.json"
compile_paths >"${model_json}" || fail "P1 the example does not compile, so no loopback separation can be asserted"

# P1: every runtime target carries its own loopback fact.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    site = d.control_plane_model.data.esp0xdeadbeef."site-a";
    targets = site.runtimeTargets;
    names = builtins.attrNames targets;
    withLoopback = builtins.filter
      (n: (targets.${n}.effectiveRuntimeRealization.loopback.addr4 or null) != null)
      names;
  in
    builtins.length names > 0 && builtins.length withLoopback == builtins.length names
' | grep -qx true; then
  fail "P1 not every runtime target carries its own loopback fact, so loopback behaviour is not per-scope"
fi

# P2: no client's advertised resolver may be another scope's loopback address.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    site = d.control_plane_model.data.esp0xdeadbeef."site-a";
    targets = site.runtimeTargets;
    names = builtins.attrNames targets;

    loopbackOf = n: targets.${n}.effectiveRuntimeRealization.loopback.addr4 or null;

    # Advertised resolvers per target, flattened across dhcp4/dhcpv6.
    advertisedOf =
      n:
      let
        adv = targets.${n}.advertisements or { };
        dhcp4 = adv.dhcp4 or { };
        servers = builtins.concatLists (
          map (s: s.dnsServers or [ ]) (builtins.attrValues dhcp4)
        );
      in
        servers;

    # A foreign loopback is any loopback address not belonging to this target.
    isForeignLoopback = n: value:
      let
        own = loopbackOf n;
        allLoopbacks = builtins.filter (x: x != null) (map loopbackOf names);
      in
        value != own && builtins.elem value allLoopbacks;

    offenders = builtins.concatLists (
      map (n: builtins.filter (v: isForeignLoopback n v) (advertisedOf n)) names
    );
  in
    offenders == [ ]
' | grep -qx true; then
  fail "P2 a client is advertised another scope's loopback as its resolver, so loopback behaviour grants unrelated client recursion"
fi

echo "PASS loopback-resolver-separation"
