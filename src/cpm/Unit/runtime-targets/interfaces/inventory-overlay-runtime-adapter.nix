{ helpers
, common
, sitePath
, enterpriseName
, siteName
,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs requireString;
  binderSourceAudit = import ../../../binder-source-audit.nix { inherit helpers; };
in
{ nodeName, nodeRole, targetId, overlayName, overlayCfg }:
let
  runtimeNodePath = "inventory.controlPlane.sites.${enterpriseName}.${siteName}.overlays.${overlayName}.runtimeNodes.${nodeName}";
  runtimeNode = requireAttrs runtimeNodePath overlayCfg.runtimeNodes.${nodeName};
  service = requireAttrs "${runtimeNodePath}.service" (runtimeNode.service or null);
  runtimeIfName = requireString "${runtimeNodePath}.service.interface" (service.interface or null);
  provider = overlayCfg.provider or null;
  adapterClass = if isNonEmptyString provider then "vpn" else "overlay";
  entryName = "overlay-${overlayName}";
  nodeOverlay = common.attrsOrEmpty ((common.attrsOrEmpty (overlayCfg.nodes or null)).${nodeName} or null);
  boundaryIdentity = {
    kind = "virtual-adapter-hygiene-boundary";
    inherit adapterClass provider;
    sourceKind = "overlay";
    logicalInterface = entryName;
    boundary = "overlay-vpn-adapter";
    owningRole = nodeRole;
    overlay = overlayName;
  };
  sourceScopeAuthority = {
    authority = "control-plane-model";
    mode = "structured-source-scope";
    sourceClass = "overlay-runtime-adapter";
    sourceRequired = true;
    failClosedWhenAbsent = true;
    sourceFacts = [
      "overlay.provider"
      "overlay.runtimeNodes.*.service.interface"
      "overlay.nodes.*.addr4"
      "overlay.nodes.*.addr6"
    ];
    cpmFacts = [
      "forwardingIntent.rules.sourcePrefixes"
      "forwardingIntent.rules.sourceScope"
      "forwardingIntent.rules.candidateEgress"
      "forwardingIntent.rules.policyPointTraversal"
    ];
  };
  hygieneDecision = {
    decision = "preserve-virtual-boundary";
    enforcement = "fail-closed";
    trafficClasses = [ "overlay-control" "overlay-service" ];
    unscopedSourceAccepted = false;
    interfaceTupleOnlyAuthority = false;
    diagnostic = "FS-305-HDS-010-SDS-010-SMS-010: virtual adapter traffic must retain structured source authority before renderer handoff";
  };
  spoofing = {
    rejection = "fail-closed";
    spoofedSourceAccepted = false;
    interfaceTupleOnlyBypass = false;
    diagnostic = "FS-305-HDS-010-SDS-010-SMS-010: spoofed or interface-only virtual-adapter source authority is rejected";
  };
  hygieneBoundary = {
    inherit boundaryIdentity sourceScopeAuthority hygieneDecision spoofing;
    provenance = {
      route = {
        gate = "route-intent-and-policy-only-classification";
        sourceFacts = [ "routes.*.intent.kind" "routes.*.policyOnly" "routes.*.lane" ];
      };
      firewall = {
        gate = "relation-handoff";
        sourceFacts = [
          "communicationContract.relations.id"
          "forwardingIntent.rules.action"
          "forwardingIntent.rules.sourceScope"
          "forwardingIntent.rules.policyPointTraversal"
        ];
      };
      nat = {
        gate = "route-safety";
        sourceFacts = [
          "runtimeTargets.*.natIntent.routeSafety.coreOriginUplinkDefault"
          "runtimeTargets.*.natIntent.translationRecords"
        ];
      };
      providerEgress = {
        gate = "provider-egress-source";
        sourceFacts = [ "overlay.provider" "overlay.runtimeNodes.*.service.interface" ];
      };
    };
  };
  value =
    {
      runtimeTarget = targetId;
      logicalNode = nodeName;
      sourceInterface = entryName;
      sourceKind = "overlay";
      runtimeIfName = runtimeIfName;
      renderedIfName = runtimeIfName;
      addr4 = nodeOverlay.addr4 or null;
      addr6 = nodeOverlay.addr6 or null;
      routes = {
        ipv4 = [ ];
        ipv6 = [ ];
      };
      backingRef = {
        kind = "overlay";
        id = "overlay::${enterpriseName}.${siteName}::${overlayName}";
        name = overlayName;
      };
      adapterClass = adapterClass;
      owningRole = nodeRole;
      virtualAdapter = true;
      hostFacing = false;
      exclusionReason = "overlay-tunnel-adapter";
      tunnelPurpose = "overlay-reachability";
      overlay = overlayName;
      inherit boundaryIdentity sourceScopeAuthority hygieneDecision spoofing hygieneBoundary;
    }
    // (if isNonEmptyString provider then { inherit provider; } else { })
    // (if isNonEmptyString (service.name or null) then { runtimeService = service.name; } else { })
    // (if builtins.isList (runtimeNode.groups or null) then { groups = runtimeNode.groups; } else { })
    // binderSourceAudit.make {
      path = runtimeNodePath;
      field = "effectiveRuntimeRealization.interfaces.${entryName}";
      binderSourceClass = "public-inventory";
      binderSourcePath = runtimeNodePath;
      upstreamBehaviorRef = "${sitePath}.nodes.${nodeName}";
    };
in
{
  name = entryName;
  inherit value;
}
