#!/usr/bin/env bash
# GAMP-ID: FS-400-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"
result_json="${tmp_dir}/result.json"

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "overlay-client-gua-mode-contract: missing network-labs input" else labsPath
  '
)"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
    "${output_json}" >/dev/null
)

OUTPUT_JSON="${output_json}" REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
    system = builtins.currentSystem;
    pkgs = import flake.inputs.nixpkgs { inherit system; };
    helpers = import ./src/cpm/cpm-contract-support.nix { inherit (pkgs) lib; };
    common = import ./src/cpm/Site/build-data/common.nix {
      inherit helpers;
      ipam = import ./src/cpm/ipam.nix { inherit (pkgs) lib; };
      enterpriseRoot = { };
    };
    overlayClientGuaContract = import ./src/cpm/Site/build-data/overlay-client-gua-mode.nix {
      inherit helpers common;
    };

    hostilePrefixSource = "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile";
    siteB = data.control_plane_model.data.espbranch."site-b";
    siteBOverlayModes = (siteB.ipv6 or { }).internetModes.overlayClientGua or [ ];
    siteBDiagnostics = (siteB.ipv6 or { }).diagnostics.overlayClientGua or [ ];

    hasHostileOverlayMode =
      builtins.any
        (record:
          (record.mode or null) == "overlay-client-gua"
          && (record.overlay or null) == "east-west"
          && (record.sourceFile or null) == hostilePrefixSource
          && (record.tenant or null) == "hostile"
          && (record.exitNode or null) == "b-router-access-hostile"
          && (record.egressRuntimeTarget or null) == "espbranch-site-b-b-router-core-nebula"
          && (record.egressInterface or null) == "overlay-east-west"
          && ((record.defaultRoute or { }).proto or null) == "overlay"
          && ((record.defaultRoute or { }).overlay or null) == "east-west"
          && builtins.any
            (returnRoute:
              (returnRoute.sourceFile or null) == hostilePrefixSource
              && (returnRoute.runtimeTarget or null) == "espbranch-site-b-b-router-access-hostile")
            (record.returnRoutes or [ ])
          && builtins.any
            (returnRoute:
              (returnRoute.sourceFile or null) == hostilePrefixSource
              && (returnRoute.runtimeTarget or null) == "espbranch-site-b-b-router-upstream-selector"
              && (returnRoute.via6 or null) == "fd42:dead:feed:1000:0:0:0:10")
            (record.returnRoutes or [ ]))
        siteBOverlayModes;

    completeSynthetic = overlayClientGuaContract {
      runtimeTargets = {
        core.effectiveRuntimeRealization.interfaces.overlay = {
          sourceKind = "overlay";
          backingRef.name = "east-west";
          routes.ipv6 = [
            {
              dst = "::/0";
              proto = "overlay";
              policyOnly = true;
              sourceFile = hostilePrefixSource;
              tenant = "hostile";
              intent = {
                kind = "delegated-public-egress";
                exitNode = "access-hostile";
              };
            }
            {
              sourceFile = hostilePrefixSource;
              proto = "overlay";
              intent.kind = "runtime-routed-prefix-return";
            }
          ];
        };
      };
    };
    missingReturn = overlayClientGuaContract {
      runtimeTargets = {
        core.effectiveRuntimeRealization.interfaces.overlay = {
          sourceKind = "overlay";
          backingRef.name = "east-west";
          routes.ipv6 = [
            {
              dst = "::/0";
              proto = "overlay";
              policyOnly = true;
              sourceFile = hostilePrefixSource;
              tenant = "hostile";
              intent = {
                kind = "delegated-public-egress";
                exitNode = "access-hostile";
              };
            }
          ];
        };
      };
    };
    missingSource = overlayClientGuaContract {
      runtimeTargets = {
        core.effectiveRuntimeRealization.interfaces.overlay = {
          sourceKind = "overlay";
          backingRef.name = "east-west";
          routes.ipv6 = [
            {
              dst = "::/0";
              proto = "overlay";
              policyOnly = true;
              intent.kind = "delegated-public-egress";
            }
          ];
        };
      };
    };

    syntheticComplete =
      completeSynthetic.diagnostics == [ ]
      && builtins.length completeSynthetic.records == 1
      && ((builtins.head completeSynthetic.records).mode or null) == "overlay-client-gua";

    missingReturnDiagnostic =
      missingReturn.records == [ ]
      && missingReturn.diagnostics == [
        {
          code = "overlay-client-gua-authority-unavailable";
          mode = "fail-closed";
          missing = [ "return-behavior" ];
          message = "Policy-routed overlay client GUA mode requires overlay path, source scope, and return behavior before renderer output.";
          overlay = "east-west";
          sourceFile = hostilePrefixSource;
          tenant = "hostile";
          exitNode = "access-hostile";
        }
      ];

    missingSourceDiagnostic =
      missingSource.records == [ ]
      && missingSource.diagnostics == [
        {
          code = "overlay-client-gua-authority-unavailable";
          mode = "fail-closed";
          missing = [ "source-scope" "return-behavior" ];
          message = "Policy-routed overlay client GUA mode requires overlay path, source scope, and return behavior before renderer output.";
          overlay = "east-west";
        }
      ];
  in
  {
    checks = {
      inherit
        hasHostileOverlayMode
        syntheticComplete
        missingReturnDiagnostic
        missingSourceDiagnostic
        ;
      noSiteBDiagnostics = siteBDiagnostics == [ ];
    };
    context = {
      inherit siteBOverlayModes siteBDiagnostics completeSynthetic missingReturn missingSource;
    };
  }
' >"${result_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${result_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL overlay-client-gua-mode-contract" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  echo "resolved context:" >&2
  jq '.context' "${result_json}" >&2
  exit 1
fi

echo "PASS overlay-client-gua-mode-contract"
