{
  helpers,
  common,
  sitePath,
  siteOverlayNameSet,
  runtimeTargetNames,
  runtimeTargetsWithWANDefaults,
  transitEndpointAddressesByNode,
  sortedCandidatePaths,
  preferredFirstHopMatchesSource,
  explicitDefaultSourceSet4,
  explicitDefaultSourceSet6,
  isDelegatedIPv6AccessNode,
  routeHelpers,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs requireString sortedNames;
  inherit (common)
    accessNodeNameFromAdjacencyId
    attrsOrEmpty
    buildInternalDefaultRoute
    listOrEmpty
    uplinkNameFromAdjacencyId
    ;
  inherit (routeHelpers)
    findInterfaceNameForAdjacency
    ;
  explicitDefaultPreservation = import ./explicit-default-preservation.nix {
    inherit helpers common sitePath siteOverlayNameSet isDelegatedIPv6AccessNode;
  };

  targetInterfaces = targetPath: target:
    let
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
    in
    {
      inherit effective;
      interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
    };

  defaultRouteSanitizer = import ./default-route-sanitizer.nix {
    inherit common helpers isDelegatedIPv6AccessNode siteOverlayNameSet targetInterfaces;
  };
  delegatedOverlayEgress = import ./delegated-overlay-egress.nix {
    inherit helpers common;
  };
  endpointRoutes = import ./endpoint-routes.nix {
    inherit
      helpers
      common
      sitePath
      targetInterfaces
      transitEndpointAddressesByNode
      sortedCandidatePaths
      preferredFirstHopMatchesSource
      routeHelpers
      ;
  };
  inherit (defaultRouteSanitizer)
    sanitizeDefaultRoutes
    sanitizeDefaultRoutesForInterface
    sanitizeOverlayDefaults
    ;

  addInternalDefaults = family: sourceSet: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      targetWithoutOverlayDefaults = sanitizeOverlayDefaults family targetPath target;
      logicalNode = requireAttrs "${targetPath}.logicalNode" (targetWithoutOverlayDefaults.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      targetRole = targetWithoutOverlayDefaults.role or null;
      isSelfDefaultSource = hasAttr nodeName sourceSet;
      sourceSetForTarget =
        if isSelfDefaultSource && targetRole == "downstream-selector" then builtins.removeAttrs sourceSet [ nodeName ] else sourceSet;
      delegatedSourceNodes = builtins.filter isDelegatedIPv6AccessNode (sortedNames sourceSetForTarget);
      targetWithDelegatedOverlayEgress =
        if family == 6 && delegatedSourceNodes != [ ] then
          let
            targetView = targetInterfaces targetPath targetWithoutOverlayDefaults;
            interfacesWithDelegatedOverlayEgress =
              builtins.foldl'
                (interfaces: sourceNode:
                  delegatedOverlayEgress.add {
                    family = family;
                    sourceNode = sourceNode;
                    metric = 50;
                    interfaces = interfaces;
                  })
                targetView.interfaces
                delegatedSourceNodes;
          in
          targetWithoutOverlayDefaults
          // {
            effectiveRuntimeRealization = targetView.effective // { interfaces = interfacesWithDelegatedOverlayEgress; };
          }
        else
          targetWithoutOverlayDefaults;
      candidatePaths = builtins.filter (preferredFirstHopMatchesSource family) (sortedCandidatePaths family sourceSetForTarget nodeName);
    in
    if (isSelfDefaultSource && targetRole != "downstream-selector") || candidatePaths == [ ] then
      targetWithDelegatedOverlayEgress
    else
      let
        targetView = targetInterfaces targetPath targetWithDelegatedOverlayEgress;
        sanitized =
          builtins.mapAttrs
            (_: iface:
              let routes = attrsOrEmpty (iface.routes or null);
              in iface // { routes = routes // (if family == 4 then { ipv4 = sanitizeDefaultRoutesForInterface 4 iface (routes.ipv4 or [ ]); } else { ipv6 = sanitizeDefaultRoutesForInterface 6 iface (routes.ipv6 or [ ]); }); })
            targetView.interfaces;
        updateForCandidate = state: candidate:
          let
            idx = state.index;
            firstStep = builtins.elemAt candidate.steps 0;
            interfaceName = findInterfaceNameForAdjacency targetName target firstStep.adjacencyId;
            accessNodeName = accessNodeNameFromAdjacencyId firstStep.adjacencyId;
            uplinkName = uplinkNameFromAdjacencyId firstStep.adjacencyId;
            delegatedWANFirstHop = isNonEmptyString accessNodeName && isDelegatedIPv6AccessNode accessNodeName && isNonEmptyString uplinkName && !hasAttr uplinkName siteOverlayNameSet;
            interfacesWithDelegatedOverlayEgress =
              if family == 6 && isDelegatedIPv6AccessNode candidate.sourceNode then
                delegatedOverlayEgress.add {
                  family = family;
                  sourceNode = candidate.sourceNode;
                  metric = 50 + (idx * 100);
                  interfaces = state.interfaces;
                }
              else
                state.interfaces;
          in
          if interfaceName == null || delegatedWANFirstHop then
            state // {
              index = idx + 1;
              interfaces = interfacesWithDelegatedOverlayEgress;
            }
          else
            let
              iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}" interfacesWithDelegatedOverlayEgress.${interfaceName};
              routes = attrsOrEmpty (iface.routes or null);
              existing = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
              defaultRoute =
                (buildInternalDefaultRoute family candidate.sourceNode firstStep.via (100 + (idx * 100)))
                // (if (firstStep.laneMeta or { }) != { } then { lane = firstStep.laneMeta; } else { });
              updated = existing ++ [ defaultRoute ];
              updatedIface = iface // { routes = routes // (if family == 4 then { ipv4 = updated; } else { ipv6 = updated; }); };
            in
            { index = idx + 1; interfaces = interfacesWithDelegatedOverlayEgress // { ${interfaceName} = updatedIface; }; };
        updated = builtins.foldl' updateForCandidate { index = 0; interfaces = sanitized; } (builtins.filter (candidate: candidate.steps != [ ]) candidatePaths);
      in
      target // { effectiveRuntimeRealization = targetView.effective // { interfaces = updated.interfaces; }; };

  buildTarget = targetName:
    let
      target0 = runtimeTargetsWithWANDefaults.${targetName};
      target1 = endpointRoutes.add 4 targetName target0;
      target2 = endpointRoutes.add 6 targetName target1;
      target3 = addInternalDefaults 4 explicitDefaultSourceSet4 targetName target2;
      target4 = addInternalDefaults 6 explicitDefaultSourceSet6 targetName target3;
      target5 = explicitDefaultPreservation.restore { inherit targetName; originalTarget = target0; resolvedTarget = target4; };
    in
    { name = targetName; value = target5; };

in
{
  runtimeTargetsWithSynthesizedDefaults = builtins.listToAttrs (builtins.map buildTarget runtimeTargetNames);
}
