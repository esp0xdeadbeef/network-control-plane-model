{ helpers }:

{ hostTrafficExceptionRecords ? [ ] }:

let
  inherit (helpers) hasAttr;

  nonExemptTrafficClasses = [ "tenant" "payload" ];

  validateNonExemptBoundary = record:
    let
      hasTrafficClass = hasAttr "trafficClass" record && builtins.isString record.trafficClass && record.trafficClass != "";
      hasHostLocalAuthority = hasAttr "hostLocalAuthority" record && builtins.isBool record.hostLocalAuthority && record.hostLocalAuthority;
      hasWouldCreateForwardingExposure = hasAttr "wouldCreateForwardingExposure" record && builtins.isBool record.wouldCreateForwardingExposure && record.wouldCreateForwardingExposure;
      hasWouldCreateServiceExposure = hasAttr "wouldCreateServiceExposure" record && builtins.isBool record.wouldCreateServiceExposure && record.wouldCreateServiceExposure;

      trafficClassNonExempt = hasTrafficClass && builtins.elem record.trafficClass nonExemptTrafficClasses;

      diagnostics =
        builtins.concatLists [
          (if hasWouldCreateForwardingExposure then
            [ {
              code = "forwarding-exposure";
              message = "exception would create forwarding exposure";
            } ]
          else [ ])
          (if hasWouldCreateServiceExposure then
            [ {
              code = "service-exposure";
              message = "exception would create service exposure";
            } ]
          else [ ])
          (if trafficClassNonExempt then
            [ {
              code = "traffic-class-non-exempt";
              field = "trafficClass";
              actual = record.trafficClass;
              message = "traffic class is not eligible for host-traffic exception";
            } ]
          else [ ])
          (if hasTrafficClass && record.trafficClass == "payload" && !hasHostLocalAuthority then
            [ {
              code = "payload-lacks-host-local-authority";
              field = "hostLocalAuthority";
              message = "payload traffic lacks explicit host-local authority";
            } ]
          else [ ])
        ];

      nonExempt = diagnostics != [ ];
    in
    {
      inherit record diagnostics nonExempt;
    };

  validated = builtins.map validateNonExemptBoundary hostTrafficExceptionRecords;

  nonExemptResults = builtins.filter (v: v.nonExempt) validated;
  cleanResults = builtins.filter (v: !v.nonExempt) validated;

  nonExemptClassifications = builtins.map (v: {
    record = v.record;
    decision = "non-exempt";
    diagnostics = v.diagnostics;
  }) nonExemptResults;

  forwardingExposures = builtins.filter (v:
    builtins.any (d: d.code == "forwarding-exposure") v.diagnostics
  ) nonExemptResults;

  serviceExposures = builtins.filter (v:
    builtins.any (d: d.code == "service-exposure") v.diagnostics
  ) nonExemptResults;

in
{
  inherit nonExemptClassifications;

  summary = {
    totalRecords = builtins.length hostTrafficExceptionRecords;
    nonExemptCount = builtins.length nonExemptResults;
    cleanCount = builtins.length cleanResults;
    hasForwardingExposures = forwardingExposures != [ ];
    hasServiceExposures = serviceExposures != [ ];
    hasDiagnostics = nonExemptResults != [ ];
  };

  crossValidationContract = {
    totalCleanRecords = builtins.length cleanResults;
    cleanRecords = builtins.map (v: v.record) cleanResults;
  };
}
