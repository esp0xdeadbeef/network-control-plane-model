#!/usr/bin/env bash
# GAMP-ID: FS-166-HDS-010-SDS-010-SMS-900
# GAMP-SCOPE: software-module-test; compileAndBuildFromPaths renderer-input pass-through
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL cpm-layer-entry-compile-and-build-from-paths-renderer-input: $*" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

input_path="${tmpdir}/renderer-input.nix"
inventory_path="${tmpdir}/inventory.nix"

cat >"${input_path}" <<'EOF'
{
  control_plane_model = {
    meta = {
      traceId = "FS-166-HDS-010-SDS-010-SMS-900__mini-runtime";
      source = "test renderer-input";
    };
    deployment.hosts.s-router-nixos = {
      uplinks = { };
      bridgeNetworks = { };
    };
    render.hosts.s-router-nixos.deploymentHost = "s-router-nixos";
    realization.nodes = { };
    data.acme.lab = {
      enterprise = "acme";
      siteName = "acme.lab";
      runtimeTargets.poc-router = {
        placement.host = "s-router-nixos";
        logicalNode = {
          enterprise = "acme";
          site = "lab";
          name = "poc-router";
        };
        role = "access";
        containers = [
          {
            name = "default";
            container = "poc-router";
          }
        ];
        effectiveRuntimeRealization.interfaces = { };
      };
    };
  };
}
EOF

cat >"${inventory_path}" <<'EOF'
{ }
EOF

nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "
  let
    flake = builtins.getFlake \"path:${repo_root}\";
    api = flake.libBySystem.\${builtins.currentSystem};
    out = api.compileAndBuildFromPaths {
      inputPath = \"${input_path}\";
      inventoryPath = \"${inventory_path}\";
    };
    layerEntry = out.control_plane_model.meta.layerEntry;
    warningCodes = map (warning: warning.code) layerEntry.warnings;
    require = cond: msg: if cond then true else throw msg;
  in
    require (out.control_plane_model.meta.traceId == \"FS-166-HDS-010-SDS-010-SMS-900__mini-runtime\")
      \"renderer-input pass-through must preserve control-plane metadata\"
    && require (builtins.hasAttr \"s-router-nixos\" out.deploymentHosts)
      \"renderer-input pass-through must expose deploymentHosts for host modules\"
    && require (out.control_plane_model.data.acme.lab.runtimeTargets.poc-router.role == \"access\")
      \"renderer-input pass-through must preserve runtime targets\"
    && require (layerEntry.repo == \"network-control-plane-model\")
      \"layer-entry metadata must identify CPM as the pass-through repo\"
    && require (layerEntry.entryBoundary == \"renderer-input\")
      \"layer-entry metadata must record renderer-input boundary\"
    && require layerEntry.repoSkipped
      \"CPM must mark itself skipped for renderer-input\"
    && require (layerEntry.inputTreatment == \"pass-through\")
      \"CPM renderer-input treatment must be pass-through\"
    && require (warningCodes == [
      \"WARN_LAYER_ENTRY_SKIPS_NETWORK_LABS_INTENT_SOURCE\"
      \"WARN_LAYER_ENTRY_SKIPS_NETWORK_COMPILER\"
      \"WARN_LAYER_ENTRY_SKIPS_NFM\"
      \"WARN_LAYER_ENTRY_SKIPS_CPM\"
    ])
      \"renderer-input pass-through must carry all skipped-stage warning codes\"
" >/dev/null || fail "compileAndBuildFromPaths renderer-input contract failed"

echo "PASS cpm-layer-entry-compile-and-build-from-paths-renderer-input"
