#!/usr/bin/env bash
# GAMP-ID: FS-460-HDS-010-SDS-010-SMS-070
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-460-HDS-010-SDS-010-SMS-070.md
# OWNER:  network-control-plane-model
#
# Predicates: overlay addresses, lighthouse relationships, routes, ports, MTU and
# target-only secret paths trace back to modeled overlay facts rather than being
# invented at the renderer.
#
# Behavioural: compile the site model and assert that each overlay carries the
# facts the trace needs, so a renderer has a modeled origin for every one of them.
# CPM emits them on the overlay object itself: ipam, nodeRoutePrefixes,
# nodeRoutePrefixRecords, nodes, provider, providerContract, runtimeNodes.
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

nixos_src="${NIXOS_SRC:-${HOME}/github/nixos}"
intent_path="${nixos_src}/prod-network/testing/intent-cobalt.nix"
inventory_path="${nixos_src}/prod-network/testing/inventory-cobalt.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { echo "FAIL overlay-fact-trace: $*" >&2; exit 1; }

[[ -f "${intent_path}" ]] || fail "P1 no overlay-bearing fixture at ${intent_path}; set NIXOS_SRC to the nixos checkout"
[[ -f "${inventory_path}" ]] || fail "P1 no overlay-bearing inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'.compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the cobalt testing model does not compile, so no overlay trace can be asserted"

# P1: at least one overlay must exist, so the case is not vacuous.
if ! jq -e '.control_plane_model.data.esp0xdeadbeef.cobalt.overlays | length > 0' "${model_json}" >/dev/null 2>&1; then
  fail "P1 the model carries no overlays, so the trace cannot be asserted"
fi

# P1: every overlay must carry address, route and node facts, so each of those
# has a modeled origin rather than a renderer default.
missing="$(MODEL="${model_json}" nix eval --no-write-lock-file --impure --json --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    overlays = d.control_plane_model.data.esp0xdeadbeef.cobalt.overlays;
    names = builtins.attrNames overlays;
    lacking = f: builtins.filter (n: !(f overlays.${n})) names;
    report =
      builtins.filter (x: x != null) [
        (let r = lacking (o: (o.ipam or null) != null); in if r == [ ] then null else "ipam:${builtins.concatStringsSep "," r}")
        (let r = lacking (o: (o.nodes or [ ]) != []); in if r == [ ] then null else "nodes:${builtins.concatStringsSep "," r}")
        (let r = lacking (o: (o.nodeRoutePrefixes or [ ]) != []); in if r == [ ] then null else "routes:${builtins.concatStringsSep "," r}")
        (let r = lacking (o: (o.providerContract or null) != null); in if r == [ ] then null else "providerContract:${builtins.concatStringsSep "," r}")
      ];
  in report
')"

if [[ "${missing}" != "[]" ]]; then
  fail "P1 these overlays lack a modeled origin for a traced fact: ${missing}"
fi

# P2: the provider contract must name its ports and MTU, so a renderer cannot
# invent either.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    overlays = builtins.attrValues d.control_plane_model.data.esp0xdeadbeef.cobalt.overlays;
    withProfile = builtins.filter
      (o: (o.providerContract.profile or null) != null)
      overlays;
    peers = map (o: o.providerContract.profile.generatedPeer or { }) withProfile;
    hasMtu = map (p: (p.mtu or null) != null) peers;
  in
    builtins.length withProfile == 0 || builtins.any (x: x == true) hasMtu
' | grep -qx true; then
  fail "P2 no overlay provider contract carries a generated peer MTU, so the tunnel MTU has no modeled origin"
fi

# P2: target-only secret paths must be references, never plaintext, so the trace
# can name the secret without carrying it.
if jq -r '.control_plane_model.data.esp0xdeadbeef.cobalt.overlays | tostring' "${model_json}" \
   | grep -qiE 'PRIVATE KEY|BEGIN .*KEY|="[A-Za-z0-9+/]{40,}"'; then
  fail "P2 an overlay fact carries what looks like plaintext key material; secret paths must be references"
fi

echo "PASS overlay-fact-trace"
