{ lib
, accessSpaceDiscovery
, helpers
, common
, communicationContract
, enterpriseName
, forwardingSemantics
, overlayProvisioning
, policyAttrs
, policyEndpointBindings
, routedPrefixesByTenant
, routingMode
, runtimeTargets
, services
, siteControlPlaneCfg
, siteDisplayName
, siteId
, siteName
, tenantPrefixOwners
, trafficPaths
,
}:

let
  inherit (helpers) sortedNames;
  inherit (common) attrsOrEmpty uniqueStrings;

  runtimeTargetNames = sortedNames runtimeTargets;
  overlayNames = sortedNames overlayProvisioning;
  providerAuthorityClassifier = import ./provider-authority-classification.nix {
    inherit helpers common;
  };

  siteScope = {
    kind = "site";
    enterprise = enterpriseName;
    site = siteName;
    siteId = siteId;
    siteName = siteDisplayName;
  };

  sharedMetadata = reason: paths:
    builtins.map
      (path: {
        classification = "required-shared-metadata";
        inherit path reason;
      })
      paths;

  interfacesFor = target:
    attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);

  overlayNamesForTarget = target:
    uniqueStrings (
      builtins.filter
        (name: name != null)
        (
          builtins.map
            (iface:
              let
                backingRef = attrsOrEmpty (iface.backingRef or null);
              in
              if (backingRef.kind or null) == "overlay" then backingRef.name or null else null)
            (builtins.attrValues (interfacesFor target))
        )
    );

  runtimeScopedArtifacts =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target = runtimeTargets.${targetName};
            targetOverlayNames = overlayNamesForTarget target;
          in
          {
            name = targetName;
            value = {
              emissionStage = "control-plane-model-before-renderer";
              scope = siteScope // {
                kind = "runtimeTarget";
                runtimeTarget = targetName;
                logicalNode = target.logicalNode or null;
              };
              payloadRef = "control_plane_model.data.${enterpriseName}.${siteName}.runtimeTargets.${targetName}";
              payload = {
                logicalNode = target.logicalNode or null;
                role = target.role or null;
                routingMode = target.routingMode or null;
              };
              includedSharedMetadata =
                sharedMetadata "runtime target identity and portable renderer context" [
                  "runtimeTargets.${targetName}"
                  "siteId"
                  "siteName"
                  "routing.mode"
                  "overlays"
                ];
              includedOverlayNames = targetOverlayNames;
              excluded = {
                unrelatedRuntimeTargets =
                  builtins.filter (name: name != targetName) runtimeTargetNames;
                unrelatedSites = "not-present-in-site-scoped-cpm-record";
                protectedValues = "references-only";
              };
            };
          })
        runtimeTargetNames
    );

  providerProfileEntries =
    builtins.concatMap
      (overlayName:
        let
          overlay = overlayProvisioning.${overlayName};
          providerName = overlay.provider or null;
          terminateOn = overlay.terminateOn or [ ];
          targetNames =
            builtins.filter
              (targetName:
                let
                  logicalNode = (runtimeTargets.${targetName}.logicalNode or { }).name or null;
                in
                builtins.elem logicalNode terminateOn)
              runtimeTargetNames;
        in
        if providerName == null then
          [ ]
        else
          [
            {
              name = "${providerName}__${overlayName}";
              value = {
                emissionStage = "control-plane-model-before-renderer";
                scope = siteScope // {
                  kind = "providerProfile";
                  provider = providerName;
                  overlay = overlayName;
                };
                payload = overlay;
                providerAuthority = providerAuthorityClassifier.classify {
                  inherit overlayName overlay;
                };
                includedRuntimeTargets = targetNames;
                includedSharedMetadata =
                  sharedMetadata "provider overlay realization and portable comparison context" [
                    "siteId"
                    "siteName"
                    "overlays.${overlayName}.provider"
                    "overlays.${overlayName}.terminateOn"
                  ];
                excluded = {
                  unrelatedProviderProfiles =
                    builtins.filter
                      (name: name != overlayName)
                      overlayNames;
                  unrelatedSites = "not-present-in-site-scoped-cpm-record";
                  protectedValues = "references-only";
                };
              };
            }
          ])
      overlayNames;

  rendererTargets = attrsOrEmpty (siteControlPlaneCfg.rendererTargets or null);

  hasAnyNat =
    builtins.any
      (targetName: ((runtimeTargets.${targetName}.natIntent or { }).enabled or false) == true)
      runtimeTargetNames;

  hasPublicIngress =
    builtins.any
      (service:
        builtins.any
          (record: (record.exposureClass or null) == "public-ingress")
          (((service.exposure or { }).records or [ ])))
      (if builtins.isList services then services else [ ]);

  requiredCapabilities =
    [
      {
        name = "policy";
        sourceFacts = [ "policy" "communicationContract" "accessSpaceDiscovery" ];
      }
      {
        name = "reachability";
        sourceFacts = [ "runtimeTargets" "trafficPaths" ];
      }
      {
        name = "addressAuthority";
        sourceFacts = [ "tenantPrefixOwners" "routedPrefixes" ];
      }
      {
        name = "routing";
        sourceFacts = [
          "routing"
          "runtimeTargets.*.effectiveRuntimeRealization.interfaces.*.routes"
          "runtimeTargets.*.effectiveRuntimeRealization.routeSelectionRules"
        ];
      }
      {
        name = "dns";
        sourceFacts = [ "services.*.dns" "runtimeTargets.*.services.dns" ];
      }
      {
        name = "serviceExposure";
        sourceFacts = [ "services.*.exposure" ];
      }
      {
        name = "runtimeFacts";
        sourceFacts = [ "runtimeTargets.*.effectiveRuntimeRealization" "runtimeTargets.*.placement" ];
      }
    ]
    ++ lib.optional hasAnyNat {
      name = "nat";
      sourceFacts = [ "runtimeTargets.*.natIntent" ];
    }
    ++ lib.optional hasPublicIngress {
      name = "publicIngress";
      sourceFacts = [ "services.*.exposure.records" "communicationContract.services" ];
    };

  capabilityMissing = targetCfg: capability:
    let
      supports = attrsOrEmpty (targetCfg.supports or null);
    in
    (supports.${capability.name} or false) != true;

  limitationsForTarget = targetName:
    let
      targetCfg = attrsOrEmpty rendererTargets.${targetName};
      targetScope = siteScope // {
        kind = "rendererTarget";
        rendererTarget = targetName;
        platform = targetCfg.platform or null;
        provider = targetCfg.provider or null;
      };
    in
    builtins.map
      (capability: {
        kind = "portability-limitation";
        unsupportedBehavior = capability.name;
        affectedScope = targetScope;
        requiredSourceFacts = capability.sourceFacts;
        targetCapabilityReason =
          targetCfg.capabilityReason or "renderer target does not declare support for required modeled behavior";
        decision = "block-renderer-emission";
      })
      (builtins.filter (capability: capabilityMissing targetCfg capability) requiredCapabilities);

  limitationReports =
    builtins.concatMap limitationsForTarget (sortedNames rendererTargets);

  emissionDecisions =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            reports = limitationsForTarget targetName;
          in
          {
            name = targetName;
            value = {
              allowed = reports == [ ];
              action = if reports == [ ] then "allow-renderer-emission" else "block-renderer-emission";
              limitationCount = builtins.length reports;
            };
          })
        (sortedNames rendererTargets)
    );

in
{
  scopedArtifacts = {
    runtimeTargets = runtimeScopedArtifacts;
    providerProfiles = builtins.listToAttrs providerProfileEntries;
  };
  portableMeaning = {
    comparisonAuthority = "control-plane-model";
    scope = siteScope;
    requiredBehavior = {
      policy = policyAttrs // {
        interfaceTags = policyEndpointBindings.interfaceTags;
        endpointBindings = builtins.removeAttrs policyEndpointBindings [ "interfaceTags" ];
      };
      reachability = {
        inherit trafficPaths;
        runtimeTargetNames = runtimeTargetNames;
      };
      addressAuthority = {
        tenantPrefixOwners = tenantPrefixOwners;
        routedPrefixes = routedPrefixesByTenant;
      };
      translation = {
        natRequired = hasAnyNat;
      };
      publicIngress = {
        required = hasPublicIngress;
      };
      routing = {
        mode = routingMode;
      };
      dns = {
        serviceNames = builtins.map (service: service.name or null) (if builtins.isList services then services else [ ]);
      };
      serviceExposure = {
        services = services;
      };
      runtimeFacts = {
        runtimeTargetNames = runtimeTargetNames;
      };
      forwardingSemantics = forwardingSemantics;
    }
    // (if communicationContract != null then { inherit communicationContract; } else { })
    // (if accessSpaceDiscovery != null then { inherit accessSpaceDiscovery; } else { });
    comparisonInputs = {
      rendererTargets = rendererTargets;
      requiredCapabilities = builtins.map (capability: capability.name) requiredCapabilities;
    };
  };
  limitations = limitationReports;
  rendererEmission = {
    targets = emissionDecisions;
    blocked = limitationReports != [ ];
    reason =
      if limitationReports == [ ] then
        "all declared renderer targets preserve required modeled meaning"
      else
        "one or more renderer targets cannot preserve required modeled meaning";
  };
}
