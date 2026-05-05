{
  helpers,
  common,
  sitePath,
  targetInterfaces,
  transitEndpointAddressesByNode,
  sortedCandidatePaths,
  preferredFirstHopMatchesSource,
  routeHelpers,
}:

let
  inherit (helpers) hasAttr requireAttrs requireString sortedNames;
  inherit (common)
    attrsOrEmpty
    buildInternalEndpointRoute
    listOrEmpty
    makeStringSet
    routeAlreadyPresent
    ;
  inherit (routeHelpers)
    findInterfaceNameForAdjacency
    interfaceBackingKind
    interfaceHasDefaultForFamily
    interfaceNameHasUplinkWanPreference
    interfaceNameTargetsDestination
    ;

  chooseInterface =
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
in
{
  add = family: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      endpointNodes = builtins.filter (candidate: candidate != nodeName && hasAttr candidate transitEndpointAddressesByNode) (sortedNames transitEndpointAddressesByNode);
      targetView = targetInterfaces targetPath target;
      updatedInterfaces =
        builtins.foldl'
          (currentInterfaces: destinationNode:
            let chosen = chooseInterface family targetName targetPath target targetView.interfaces destinationNode nodeName;
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
}
