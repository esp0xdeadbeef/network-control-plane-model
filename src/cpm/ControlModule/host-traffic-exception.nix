{ helpers }:

{ hostTrafficExceptionRecords ? [ ] }:

let
  inherit (helpers) hasAttr;

  allowedTargetRoles = [ "coreBoundary" ];
  allowedTrafficClasses = [ "management" "controlPlane" ];

  validateRecord = record:
    let
      hasTargetRole = hasAttr "targetRole" record && builtins.isString record.targetRole && record.targetRole != "";
      hasTargetAddress = hasAttr "targetAddress" record && builtins.isString record.targetAddress && record.targetAddress != "";
      hasProtocol = hasAttr "protocol" record && builtins.isString record.protocol && record.protocol != "";
      hasSourceScope = hasAttr "sourceScope" record && builtins.isString record.sourceScope && record.sourceScope != "";
      hasAttachmentSurface = hasAttr "attachmentSurface" record && builtins.isString record.attachmentSurface && record.attachmentSurface != "";
      hasTrafficClass = hasAttr "trafficClass" record && builtins.isString record.trafficClass && record.trafficClass != "";

      targetRoleIsCoreBoundary = hasTargetRole && builtins.elem record.targetRole allowedTargetRoles;
      trafficClassIsExempt = hasTrafficClass && builtins.elem record.trafficClass allowedTrafficClasses;

      incompleteFields =
        builtins.concatLists [
          (if hasTargetRole then [ ] else [ "targetRole" ])
          (if hasTargetAddress then [ ] else [ "targetAddress" ])
          (if hasProtocol then [ ] else [ "protocol" ])
          (if hasSourceScope then [ ] else [ "sourceScope" ])
          (if hasAttachmentSurface then [ ] else [ "attachmentSurface" ])
          (if hasTrafficClass then [ ] else [ "trafficClass" ])
        ];

      diagnostics =
        if incompleteFields != [ ] then
          [ {
            code = "incomplete-exception-data";
            missingFields = incompleteFields;
            message = "incomplete exception data: missing required fields";
          } ]
        else if !targetRoleIsCoreBoundary then
          [ {
            code = "target-role-not-core-boundary";
            field = "targetRole";
            expected = allowedTargetRoles;
            actual = record.targetRole;
          } ]
        else if !trafficClassIsExempt then
          [ {
            code = "non-exempt-traffic-class";
            field = "trafficClass";
            actual = record.trafficClass;
            allowedClasses = allowedTrafficClasses;
          } ]
        else
          [ ];

      exempt = diagnostics == [ ];
    in
    {
      inherit record exempt diagnostics;
    };

  validated = builtins.map validateRecord hostTrafficExceptionRecords;

  exemptRecords = builtins.filter (v: v.exempt) validated;
  nonExemptRecords = builtins.filter (v: !v.exempt) validated;

in
{
  rendererExceptions = builtins.map (v: {
    targetRole = v.record.targetRole;
    targetAddress = v.record.targetAddress;
    protocol = v.record.protocol;
    sourceScope = v.record.sourceScope;
    attachmentSurface = v.record.attachmentSurface;
    trafficClass = v.record.trafficClass;
    exceptionDecision = "exempt";
  }) exemptRecords;

  nonExemptClassifications = builtins.map (v: {
    record = v.record;
    decision = "non-exempt";
    diagnostics = v.diagnostics;
  }) nonExemptRecords;

  summary = {
    totalRecords = builtins.length hostTrafficExceptionRecords;
    exemptCount = builtins.length exemptRecords;
    nonExemptCount = builtins.length nonExemptRecords;
    hasDiagnostics = nonExemptRecords != [ ];
  };
}
