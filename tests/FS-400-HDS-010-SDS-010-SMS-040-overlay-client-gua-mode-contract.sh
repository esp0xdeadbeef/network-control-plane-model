#!/usr/bin/env bash
# GAMP-ID: FS-400-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

result_json="${tmp_dir}/result.json"

# This is a CPM module construction test. Current network-labs examples do not
# emit overlayClientGua records, so the proof uses explicit runtimeTarget
# fixtures for the positive path and seeded negatives.
REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
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
        syntheticComplete
        missingReturnDiagnostic
        missingSourceDiagnostic
        ;
    };
    context = {
      inherit completeSynthetic missingReturn missingSource;
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
