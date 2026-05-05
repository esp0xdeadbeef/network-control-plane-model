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
    buildInternalEndpointRoute
    listOrEmpty
    makeStringSet
    routeAlreadyPresent
    uplinkNameFromAdjacencyId
    ;
  inherit (routeHelpers)
    findInterfaceNameForAdjacency
    interfaceBackingKind
    interfaceHasDefaultForFamily
    interfaceNameHasUplinkWanPreference
    interfaceNameTargetsDestination
    ;
  explicitDefaultPreservation = import ./explicit-default-preservation.nix {
    inherit helpers common sitePath;
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
  inherit (defaultRouteSanitizer)
    sanitizeDefaultRoutes
    sanitizeOverlayDefaults
    ;

  chooseEndpointRouteInterface =
    family: targetName: targetPath: target: interfaces: destinationNode: nodeName:
    let
      endpointAddresses = transitEndpointAddressesByNode.${destinationNode};
      familyAddresses = if family == 4 then endpointAddresses.ipv4 or [ ] else endpointAddresses.ipv6 or [ ];
      candidatePaths =
        builtins.filter
          (preferredFirstHopMatchesSource family)
          (sortedCandidatePaths family (makeStringSet [ destinationNode ]) nodeName);
      usableCandidates = builtins.filter (candidate: builtins.length candidate.steps > 1) candidatePaths;
      candidateEntries =
        builtins.map
          (candidate:
            let firstStep = builtins.elemAt candidate.steps 0;
            in {
              inherit candidate firstStep;
              interfaceName = findInterfaceNameForAdjacency targetName target firstStep.adjacencyId;
            })
          usableCandidates;
      namedCandidates = builtins.filter (entry: entry.interfaceName != null) candidateEntries;
      destinationScoped = builtins.filter (entry: interfaceNameTargetsDestination entry.interfaceName destinationNode) namedCandidates;
      scopedRaw = if destinationScoped != [ ] then destinationScoped else namedCandidates;
      preferredWan = builtins.filter (entry: interfaceNameHasUplinkWanPreference entry.interfaceName) scopedRaw;
      preferredOverlay =
        builtins.filter
          (entry: interfaceBackingKind targetPath interfaces entry.interfaceName == "overlay")
          scopedRaw;
      scoped = if preferredWan != [ ] then preferredWan else if preferredOverlay != [ ] then preferredOverlay else scopedRaw;
      defaultBearing =
        builtins.filter
          (entry:
            interfaceHasDefaultForFamily family (
              requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${entry.interfaceName}" interfaces.${entry.interfaceName}
            ))
          scoped;
      chosen =
        if defaultBearing != [ ] then builtins.elemAt defaultBearing 0 else if scoped != [ ] then builtins.elemAt scoped 0 else null;
    in
    { inherit chosen familyAddresses; };

  addEndpointRoutes = family: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      endpointNodes = builtins.filter (candidate: candidate != nodeName && hasAttr candidate transitEndpointAddressesByNode) (sortedNames transitEndpointAddressesByNode);
      targetView = targetInterfaces targetPath target;
      updatedInterfaces =
        builtins.foldl'
          (currentInterfaces: destinationNode:
            let chosen = chooseEndpointRouteInterface family targetName targetPath target targetView.interfaces destinationNode nodeName;
            in
            if chosen.familyAddresses == [ ] || chosen.chosen == null then
              currentInterfaces
            else
              let
                firstStep = chosen.chosen.firstStep;
                interfaceName = chosen.chosen.interfaceName;
                iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}" currentInterfaces.${interfaceName};
                routes = attrsOrEmpty (iface.routes or null);
                existing = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
                updated =
                  builtins.foldl'
                    (accRoutes: destination:
                      if routeAlreadyPresent family accRoutes destination firstStep.via then
                        accRoutes
                      else
                        accRoutes ++ [ (buildInternalEndpointRoute family destination destinationNode firstStep.via) ])
                    existing
                    chosen.familyAddresses;
                updatedIface = iface // { routes = routes // (if family == 4 then { ipv4 = updated; } else { ipv6 = updated; }); };
              in
              currentInterfaces // { ${interfaceName} = updatedIface; })
          targetView.interfaces
          endpointNodes;
    in
    target // { effectiveRuntimeRealization = targetView.effective // { interfaces = updatedInterfaces; }; };

  addInternalDefaults = family: sourceSet: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      targetWithoutOverlayDefaults = sanitizeOverlayDefaults family targetPath target;
      logicalNode = requireAttrs "${targetPath}.logicalNode" (targetWithoutOverlayDefaults.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      candidatePaths = builtins.filter (preferredFirstHopMatchesSource family) (sortedCandidatePaths family sourceSet nodeName);
    in
    if hasAttr nodeName sourceSet || candidatePaths == [ ] then
      targetWithoutOverlayDefaults
    else
      let
        targetView = targetInterfaces targetPath targetWithoutOverlayDefaults;
        sanitized =
          builtins.mapAttrs
            (_: iface:
              let routes = attrsOrEmpty (iface.routes or null);
              in iface // { routes = routes // (if family == 4 then { ipv4 = sanitizeDefaultRoutes 4 (routes.ipv4 or [ ]); } else { ipv6 = sanitizeDefaultRoutes 6 (routes.ipv6 or [ ]); }); })
            targetView.interfaces;
        updateForCandidate = state: candidate:
          let
            idx = state.index;
            firstStep = builtins.elemAt candidate.steps 0;
            interfaceName = findInterfaceNameForAdjacency targetName target firstStep.adjacencyId;
            accessNodeName = accessNodeNameFromAdjacencyId firstStep.adjacencyId;
            uplinkName = uplinkNameFromAdjacencyId firstStep.adjacencyId;
            delegatedWANFirstHop = isNonEmptyString accessNodeName && isDelegatedIPv6AccessNode accessNodeName && isNonEmptyString uplinkName && !hasAttr uplinkName siteOverlayNameSet;
          in
          if interfaceName == null || delegatedWANFirstHop then
            state // { index = idx + 1; }
          else
            let
              iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}" state.interfaces.${interfaceName};
              routes = attrsOrEmpty (iface.routes or null);
              existing = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
              updated = existing ++ [ (buildInternalDefaultRoute family candidate.sourceNode firstStep.via (100 + (idx * 100))) ];
              updatedIface = iface // { routes = routes // (if family == 4 then { ipv4 = updated; } else { ipv6 = updated; }); };
            in
            { index = idx + 1; interfaces = state.interfaces // { ${interfaceName} = updatedIface; }; };
        updated = builtins.foldl' updateForCandidate { index = 0; interfaces = sanitized; } (builtins.filter (candidate: candidate.steps != [ ]) candidatePaths);
      in
      target // { effectiveRuntimeRealization = targetView.effective // { interfaces = updated.interfaces; }; };

  buildTarget = targetName:
    let
      target0 = runtimeTargetsWithWANDefaults.${targetName};
      target1 = addEndpointRoutes 4 targetName target0;
      target2 = addEndpointRoutes 6 targetName target1;
      target3 = addInternalDefaults 4 explicitDefaultSourceSet4 targetName target2;
      target4 = addInternalDefaults 6 explicitDefaultSourceSet6 targetName target3;
      target5 = explicitDefaultPreservation.restore {
        inherit targetName;
        originalTarget = target0;
        resolvedTarget = target4;
      };
    in
    { name = targetName; value = target5; };

in
{
  runtimeTargetsWithSynthesizedDefaults =
    builtins.listToAttrs (builtins.map buildTarget runtimeTargetNames);
}
