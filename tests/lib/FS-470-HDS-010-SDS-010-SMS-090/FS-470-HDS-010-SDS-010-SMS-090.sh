#!/usr/bin/env bash
# GAMP-ID: FS-470-HDS-010-SDS-010-SMS-090
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-470-HDS-010-SDS-010-SMS-090.md
# OWNER:  network-control-plane-model
#
# Predicates: each WireGuard overlay's tunnel MTU is derived from the overlay
# declaration, and that MTU is bound onto the access advertisements of the
# matching source access scope. The MTU comes from the upstream/tunnel interface,
# never from a client-side route or a hardcoded constant.
#
# Behavioural: compile the site model and assert on the emitted model. CPM already
# carries both surfaces this needs:
#   overlays.<name>.providerContract.profile.generatedPeer.mtu   (declaration)
#   runtimeTargets.<t>.advertisements.dhcp4[].interfaceMtu       (binding)
#
# Fixture: the cobalt testing model from the nixos repository, because the
# single-wan example models no overlay MTU. Set NIXOS_SRC to that checkout.
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

fail() { echo "FAIL wireguard-mtu-binding: $*" >&2; exit 1; }

[[ -f "${intent_path}" ]] || fail "P1 no overlay-bearing fixture at ${intent_path}; set NIXOS_SRC to the nixos checkout"
[[ -f "${inventory_path}" ]] || fail "P1 no overlay-bearing inventory at ${inventory_path}"

model_json="${tmp_dir}/model.json"
nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    }
' >"${model_json}" || fail "P1 the cobalt testing model does not compile, so no MTU binding can be asserted"

# P1: the overlay declaration must carry an MTU, so the case is not vacuous.
declared="$(
  jq -r '[.control_plane_model.data.esp0xdeadbeef.cobalt.overlays
          | to_entries[] | .value.providerContract.profile.generatedPeer.mtu
          | select(. != null)] | unique' "${model_json}"
)"
[[ "${declared}" != "[]" ]] || fail "P1 no overlay declares a tunnel MTU, so the binding cannot be asserted"

# P2: every bound advertisement MTU must equal a declared overlay MTU. A value
# that matches no declaration is a hardcoded constant or a client-side
# derivation, which the FS forbids.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    site = d.control_plane_model.data.esp0xdeadbeef.cobalt;
    declared = builtins.concatLists (
      map
        (o:
          let m = o.providerContract.profile.generatedPeer.mtu or null;
          in if m == null then [ ] else [ m ])
        (builtins.attrValues site.overlays)
    );
    targets = builtins.attrNames site.runtimeTargets;
    boundOf = n:
      let
        adv = site.runtimeTargets.${n}.advertisements.dhcp4 or [ ];
        mtus = map (a: a.interfaceMtu.value or null) adv;
      in builtins.filter (v: v != null) mtus;
    allBound = builtins.concatLists (map boundOf targets);
  in
    builtins.length allBound > 0
    && builtins.all (v: builtins.elem v declared) allBound
' | grep -qx true; then
  fail "P2 an advertised interface MTU does not match any declared overlay MTU, so it was not derived from the tunnel declaration"
fi

# P2: the binding must name its source as the overlay, not as a route or a
# default, so the derivation is inspectable.
if ! MODEL="${model_json}" nix eval --no-write-lock-file --impure --expr '
  let
    d = builtins.fromJSON (builtins.readFile (builtins.getEnv "MODEL"));
    site = d.control_plane_model.data.esp0xdeadbeef.cobalt;
    targets = builtins.attrNames site.runtimeTargets;
    boundMeta = builtins.concatLists (
      map
        (n:
          let adv = site.runtimeTargets.${n}.advertisements.dhcp4 or [ ];
              metas = map (a: a.interfaceMtu or null) adv;
          in builtins.filter (m: m != null) metas)
        targets
    );
    sourced = builtins.filter
      (m: (m.source or null) != null && (m.sourceOverlays or [ ]) != [ ])
      boundMeta;
  in
    builtins.length boundMeta > 0 && builtins.length sourced == builtins.length boundMeta
' | grep -qx true; then
  fail "P2 an interface MTU carries no overlay source, so the MTU is not traceable to the tunnel declaration"
fi

echo "PASS wireguard-mtu-binding"
