#!/usr/bin/env bash
# GAMP-ID: FS-280-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
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
      classifyHostTrafficException = import ./src/cpm/ControlModule/host-traffic-exception.nix { inherit helpers; };

      exemptRecord = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "admin";
        attachmentSurface = "mgmt-access";
        trafficClass = "management";
      };

      exemptRecordControlPlane = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "ssh";
        sourceScope = "admin";
        attachmentSurface = "control-access";
        trafficClass = "controlPlane";
      };

      tenantPayloadRecord = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "tenant-a";
        attachmentSurface = "tenant-access";
        trafficClass = "tenant";
      };

      publicIngressPayloadRecord = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "public-ingress";
        attachmentSurface = "public-wan";
        trafficClass = "payload";
      };

      missingTargetRole = {
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "admin";
        attachmentSurface = "mgmt-access";
        trafficClass = "management";
      };

      wrongTargetRole = {
        targetRole = "access-node";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "admin";
        attachmentSurface = "mgmt-access";
        trafficClass = "management";
      };

      missingProtocol = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        sourceScope = "admin";
        attachmentSurface = "mgmt-access";
        trafficClass = "management";
      };

      missingAttachmentSurface = {
        targetRole = "coreBoundary";
        targetAddress = "10.20.0.1";
        protocol = "tcp";
        sourceScope = "admin";
        trafficClass = "management";
      };

      wellFormedInputs = [
        exemptRecord
        exemptRecordControlPlane
      ];

      wellFormedResult = classifyHostTrafficException {
        hostTrafficExceptionRecords = wellFormedInputs;
      };

      tenantPayloadResult = classifyHostTrafficException {
        hostTrafficExceptionRecords = [ tenantPayloadRecord ];
      };

      publicIngressResult = classifyHostTrafficException {
        hostTrafficExceptionRecords = [ publicIngressPayloadRecord ];
      };

      missingRoleResult = classifyHostTrafficException {
        hostTrafficExceptionRecords = [ missingTargetRole ];
      };

      wrongRoleResult = classifyHostTrafficException {
        hostTrafficExceptionRecords = [ wrongTargetRole ];
      };

      missingProtocolResult = classifyHostTrafficException {
        hostTrafficExceptionRecords = [ missingProtocol ];
      };

      missingAttachmentResult = classifyHostTrafficException {
        hostTrafficExceptionRecords = [ missingAttachmentSurface ];
      };

      emptyResult = classifyHostTrafficException {
        hostTrafficExceptionRecords = [ ];
      };

      tenantDiagnostic = builtins.elemAt tenantPayloadResult.nonExemptClassifications 0;
      publicIngressDiagnostic = builtins.elemAt publicIngressResult.nonExemptClassifications 0;
      missingRoleDiagnostic = builtins.elemAt missingRoleResult.nonExemptClassifications 0;
      wrongRoleDiagnostic = builtins.elemAt wrongRoleResult.nonExemptClassifications 0;
      missingProtocolD = builtins.elemAt missingProtocolResult.nonExemptClassifications 0;
      missingAttachmentD = builtins.elemAt missingAttachmentResult.nonExemptClassifications 0;
    in {
      checks = {
        P1_wellFormedExempt = wellFormedResult.summary.totalRecords == 2
          && wellFormedResult.summary.exemptCount == 2
          && wellFormedResult.summary.nonExemptCount == 0
          && wellFormedResult.summary.hasDiagnostics == false;

        P1a_firstExempt = (builtins.elemAt wellFormedResult.rendererExceptions 0).exceptionDecision == "exempt"
          && (builtins.elemAt wellFormedResult.rendererExceptions 0).trafficClass == "management";

        P1b_secondExempt = (builtins.elemAt wellFormedResult.rendererExceptions 1).exceptionDecision == "exempt"
          && (builtins.elemAt wellFormedResult.rendererExceptions 1).trafficClass == "controlPlane";

        P3_emptyInput = emptyResult.summary.totalRecords == 0
          && emptyResult.summary.exemptCount == 0
          && emptyResult.summary.nonExemptCount == 0;

        SN1_tenantPayloadNonExempt =
          tenantPayloadResult.summary.exemptCount == 0
          && tenantPayloadResult.summary.nonExemptCount == 1
          && tenantPayloadResult.summary.hasDiagnostics == true
          && tenantDiagnostic.decision == "non-exempt"
          && (builtins.head tenantDiagnostic.diagnostics).code == "non-exempt-traffic-class"
          && (builtins.head tenantDiagnostic.diagnostics).field == "trafficClass"
          && (builtins.head tenantDiagnostic.diagnostics).actual == "tenant";

        SN2_publicIngressNonExempt =
          publicIngressResult.summary.exemptCount == 0
          && publicIngressResult.summary.nonExemptCount == 1
          && publicIngressResult.summary.hasDiagnostics == true
          && publicIngressDiagnostic.decision == "non-exempt"
          && (builtins.head publicIngressDiagnostic.diagnostics).code == "non-exempt-traffic-class"
          && (builtins.head publicIngressDiagnostic.diagnostics).field == "trafficClass"
          && (builtins.head publicIngressDiagnostic.diagnostics).actual == "payload";

        SN3_missingTargetRole =
          missingRoleResult.summary.exemptCount == 0
          && missingRoleResult.summary.nonExemptCount == 1
          && missingRoleResult.summary.hasDiagnostics == true
          && missingRoleDiagnostic.decision == "non-exempt"
          && (builtins.head missingRoleDiagnostic.diagnostics).code == "incomplete-exception-data"
          && builtins.elem "targetRole" (builtins.head missingRoleDiagnostic.diagnostics).missingFields;

        SN3a_wrongTargetRole =
          wrongRoleResult.summary.exemptCount == 0
          && wrongRoleResult.summary.nonExemptCount == 1
          && wrongRoleResult.summary.hasDiagnostics == true
          && wrongRoleDiagnostic.decision == "non-exempt"
          && (builtins.head wrongRoleDiagnostic.diagnostics).code == "target-role-not-core-boundary"
          && (builtins.head wrongRoleDiagnostic.diagnostics).field == "targetRole"
          && (builtins.head wrongRoleDiagnostic.diagnostics).actual == "access-node";

        SN4_missingProtocol =
          missingProtocolResult.summary.exemptCount == 0
          && missingProtocolResult.summary.nonExemptCount == 1
          && missingProtocolResult.summary.hasDiagnostics == true
          && missingProtocolD.decision == "non-exempt"
          && (builtins.head missingProtocolD.diagnostics).code == "incomplete-exception-data"
          && builtins.elem "protocol" (builtins.head missingProtocolD.diagnostics).missingFields;

        SN5_missingAttachmentSurface =
          missingAttachmentResult.summary.exemptCount == 0
          && missingAttachmentResult.summary.nonExemptCount == 1
          && missingAttachmentResult.summary.hasDiagnostics == true
          && missingAttachmentD.decision == "non-exempt"
          && (builtins.head missingAttachmentD.diagnostics).code == "incomplete-exception-data"
          && builtins.elem "attachmentSurface" (builtins.head missingAttachmentD.diagnostics).missingFields;
      };
    }
  ' >"${output_json}"

failed_checks="$(jq -r '.checks | to_entries[] | select(.value != true) | .key' "${output_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL FS-280-HDS-010-SDS-010-SMS-010 construction test" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<<"${failed_checks}"
  exit 1
fi

echo "PASS FS-280-HDS-010-SDS-010-SMS-010 core-host-exception construction"
