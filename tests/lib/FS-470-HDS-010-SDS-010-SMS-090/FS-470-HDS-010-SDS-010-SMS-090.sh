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
# Fixture: the pinned network-labs example `wireguard-provider-overlay`, which
# declares a WireGuard provider contract with profile.generatedPeer.mtu.
#
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
# tests/lib/pinned-paths.sh resolves the nixos testing fixtures from one
# declared location (NIXOS_SRC, then the sibling layout, then the developer
# home) instead of every case hardcoding a home directory.
source "${repo_root}/tests/lib/pinned-paths.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq

# Pinned network-labs fixture. This repository must not read fixtures out of the
# `nixos` consumer repository; `wireguard-provider-overlay` declares a WireGuard
# provider contract with `profile.generatedPeer.mtu`, which is the declaration
# this row binds the access advertisements to.
example_dir="$(pinned_lab_example wireguard-provider-overlay)"
intent_path="${example_dir}/intent.nix"
inventory_path="${example_dir}/inventory-nixos.nix"

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
' >"${model_json}" || fail "P1 the pinned lab fixture does not compile, so no MTU binding can be asserted"

# P1: the overlay declaration must carry an MTU, so the case is not vacuous.
declared="$(
  jq -r '[.control_plane_model.data.esp0xdeadbeef
          | to_entries[] | .value.overlays // {}
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
    sites = builtins.filter builtins.isAttrs (
      builtins.attrValues d.control_plane_model.data.esp0xdeadbeef
    );
    overlays = builtins.concatMap
      (s: builtins.attrValues (s.overlays or { }))
      sites;
    targetEntries = builtins.concatMap
      (s:
        let rt = s.runtimeTargets or { };
        in builtins.map (n: { name = n; value = builtins.getAttr n rt; }) (builtins.attrNames rt))
      sites;
    declared = builtins.concatLists (
      map
        (o:
          let
            pc = o.providerContract or { };
            profile = pc.profile or { };
            gp = profile.generatedPeer or { };
            m = gp.mtu or null;
          in if m == null then [ ] else [ m ])
        overlays
    );
    boundOf = entry:
      let
        adverts = entry.value.advertisements or { };
        adv = adverts.dhcp4 or [ ];
        mtus = map (a: (a.interfaceMtu or { }).value or null) adv;
      in builtins.filter (v: v != null) mtus;
    allBound = builtins.concatLists (map boundOf targetEntries);
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
    sites = builtins.filter builtins.isAttrs (
      builtins.attrValues d.control_plane_model.data.esp0xdeadbeef
    );
    overlays = builtins.concatMap
      (s: builtins.attrValues (s.overlays or { }))
      sites;
    targetEntries = builtins.concatMap
      (s:
        let rt = s.runtimeTargets or { };
        in builtins.map (n: { name = n; value = builtins.getAttr n rt; }) (builtins.attrNames rt))
      sites;
    boundMeta = builtins.concatLists (
      map
        (entry:
          let
            adverts = entry.value.advertisements or { };
            adv = adverts.dhcp4 or [ ];
            metas = map (a: a.interfaceMtu or null) adv;
          in builtins.filter (m: m != null) metas)
        targetEntries
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
