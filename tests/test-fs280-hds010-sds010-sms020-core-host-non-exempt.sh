#!/usr/bin/env bash
# GAMP-ID: FS-280-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

output_json="$(mktemp)"
trap 'rm -f "${output_json}"' EXIT

cd "${repo_root}"

nix eval \
  --extra-experimental-features 'nix-command flakes' \
  --impure --json --expr '
    let
      flake = builtins.getFlake ("path:" + toString ./.);
      system = builtins.currentSystem;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      lib = pkgs.lib;
      helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
      validateNonExempt = import ./src/cpm/ControlModule/host-traffic-non-exempt.nix { inherit helpers; };

      exemptRecord = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "admin";
        attachmentSurface = "mgmt-access";
        trafficClass = "management";
        hostLocalAuthority = true;
      };

      exemptRecordControlPlane = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "ssh";
        sourceScope = "admin";
        attachmentSurface = "control-access";
        trafficClass = "controlPlane";
        hostLocalAuthority = true;
      };

      tenantPayloadRecord = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "tenant-a";
        attachmentSurface = "tenant-access";
        trafficClass = "tenant";
        hostLocalAuthority = false;
      };

      payloadNoHostLocalAuthority = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "public-ingress";
        attachmentSurface = "public-wan";
        trafficClass = "payload";
      };

      forwardingExposureRecord = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "admin";
        attachmentSurface = "mgmt-access";
        trafficClass = "management";
        hostLocalAuthority = true;
        wouldCreateForwardingExposure = true;
      };

      serviceExposureRecord = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "admin";
        attachmentSurface = "mgmt-access";
        trafficClass = "management";
        hostLocalAuthority = true;
        wouldCreateServiceExposure = true;
      };

      wellFormedInputs = [
        exemptRecord
        exemptRecordControlPlane
      ];

      wellFormedResult = validateNonExempt {
        hostTrafficExceptionRecords = wellFormedInputs;
      };

      tenantPayloadResult = validateNonExempt {
        hostTrafficExceptionRecords = [ tenantPayloadRecord ];
      };

      payloadNoHostResult = validateNonExempt {
        hostTrafficExceptionRecords = [ payloadNoHostLocalAuthority ];
      };

      forwardingExposureResult = validateNonExempt {
        hostTrafficExceptionRecords = [ forwardingExposureRecord ];
      };

      serviceExposureResult = validateNonExempt {
        hostTrafficExceptionRecords = [ serviceExposureRecord ];
      };

      emptyResult = validateNonExempt {
        hostTrafficExceptionRecords = [ ];
      };

      tenantDiagnostic = builtins.elemAt tenantPayloadResult.nonExemptClassifications 0;
      payloadNoHostDiagnostic = builtins.elemAt payloadNoHostResult.nonExemptClassifications 0;
      forwardingExposureDiagnostic = builtins.elemAt forwardingExposureResult.nonExemptClassifications 0;
      serviceExposureDiagnostic = builtins.elemAt serviceExposureResult.nonExemptClassifications 0;
    in {
      checks = {
        P1_wellFormedClean = wellFormedResult.summary.totalRecords == 2
          && wellFormedResult.summary.nonExemptCount == 0
          && wellFormedResult.summary.cleanCount == 2
          && wellFormedResult.summary.hasForwardingExposures == false
          && wellFormedResult.summary.hasServiceExposures == false
          && wellFormedResult.summary.hasDiagnostics == false;

        P2_emptyInput = emptyResult.summary.totalRecords == 0
          && emptyResult.summary.nonExemptCount == 0
          && emptyResult.summary.cleanCount == 0;

        SN1_tenantPayloadNonExempt =
          tenantPayloadResult.summary.nonExemptCount == 1
          && tenantPayloadResult.summary.cleanCount == 0
          && tenantPayloadResult.summary.hasDiagnostics == true
          && tenantDiagnostic.decision == "non-exempt"
          && builtins.any (d: d.code == "traffic-class-non-exempt"
            && d.field == "trafficClass"
            && d.actual == "tenant") tenantDiagnostic.diagnostics;

        SN2_payloadNoHostLocalAuthority =
          payloadNoHostResult.summary.nonExemptCount == 1
          && payloadNoHostResult.summary.cleanCount == 0
          && payloadNoHostResult.summary.hasDiagnostics == true
          && payloadNoHostDiagnostic.decision == "non-exempt"
          && builtins.any (d: d.code == "traffic-class-non-exempt"
            && d.field == "trafficClass"
            && d.actual == "payload") payloadNoHostDiagnostic.diagnostics
          && builtins.any (d: d.code == "payload-lacks-host-local-authority"
            && d.field == "hostLocalAuthority") payloadNoHostDiagnostic.diagnostics;

        SN3_forwardingExposure =
          forwardingExposureResult.summary.nonExemptCount == 1
          && forwardingExposureResult.summary.cleanCount == 0
          && forwardingExposureResult.summary.hasForwardingExposures == true
          && forwardingExposureResult.summary.hasDiagnostics == true
          && forwardingExposureDiagnostic.decision == "non-exempt"
          && builtins.any (d: d.code == "forwarding-exposure"
            && d.message == "exception would create forwarding exposure") forwardingExposureDiagnostic.diagnostics;

        SN4_serviceExposure =
          serviceExposureResult.summary.nonExemptCount == 1
          && serviceExposureResult.summary.cleanCount == 0
          && serviceExposureResult.summary.hasServiceExposures == true
          && serviceExposureResult.summary.hasDiagnostics == true
          && serviceExposureDiagnostic.decision == "non-exempt"
          && builtins.any (d: d.code == "service-exposure"
            && d.message == "exception would create service exposure") serviceExposureDiagnostic.diagnostics;
      };
    }
  ' >"${output_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${output_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL FS-280-HDS-010-SDS-010-SMS-020 construction test" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  exit 1
fi

echo "PASS FS-280-HDS-010-SDS-010-SMS-020 core-host-non-exempt construction"
