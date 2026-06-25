#!/usr/bin/env bash
# GAMP-ID: FS-166-HDS-010-SDS-010-SMS-900
# GAMP-SCOPE: software-module-test; CPM layer-entry warning/pass-through contract
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL cpm-layer-entry-warning-contract: $*" >&2
  exit 1
}

nix eval --impure --expr "
  let
    flake = builtins.getFlake \"path:${repo_root}\";
    api = flake.libBySystem.\${builtins.currentSystem};
    require = cond: msg: if cond then true else throw msg;
    input = {
      control_plane_model.data.acme.lab.runtimeTargets = { };
      marker = \"FS-166-HDS-010-SDS-010-SMS-900\";
    };
    cpmConsumed = api.layerEntryEnvelope {
      entryBoundary = \"control-plane-input\";
      inherit input;
    };
    cpmSkipped = api.layerEntryEnvelope {
      entryBoundary = \"renderer-input\";
      inherit input;
    };
    warningCodes = payload: map (warning: warning.code) payload.warnings;
  in
    require (cpmConsumed.repo == \"network-control-plane-model\")
      \"CPM envelope must identify issuing repo\"
    && require (cpmConsumed.repoSkipped == false)
      \"control-plane-input must not mark CPM skipped\"
    && require (cpmConsumed.warnings == [ ])
      \"control-plane-input must not emit CPM skip warning\"
    && require (cpmSkipped.repoSkipped == true)
      \"renderer-input must mark CPM skipped\"
    && require (warningCodes cpmSkipped == [ \"WARN_LAYER_ENTRY_SKIPS_CPM\" ])
      \"renderer-input must emit the CPM skip warning from CPM\"
    && require (cpmSkipped.input == input && cpmSkipped.output == input)
      \"CPM skipped envelope must pass through the normalized input attrset\"
" >/dev/null || fail "layer-entry CPM contract failed"

echo "PASS cpm-layer-entry-warning-contract"
