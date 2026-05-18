{
  helpers,
  common,
  sitePath,
  siteOverlayNameSet,
  delegatedSourceUsesOverlayEgress,
  isDelegatedIPv6AccessNode,
  runtimeRoutedIPv6AccessNodeNames,
  sortedCandidatePaths,
  preferredFirstHopMatchesSource,
  targetInterfaces,
  sanitizeDefaultRoutesForInterface,
  sanitizeOverlayDefaults,
  delegatedOverlayEgress,
  overlayExitIngress,
  routeHelpers,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs requireString sortedNames;
  inherit (common) attrsOrEmpty buildInternalDefaultRoute listOrEmpty routeMatchesDefault;
  inherit (routeHelpers) findInterfaceNameForAdjacency;

  roleRequiresPolicyDefaults = role:
    role == "policy" || role == "upstream-selector" || role == "downstream-selector";

  markDefaultPolicyOnly = family: routes:
    builtins.map
      (route:
        if routeMatchesDefault family route then
          route // { policyOnly = true; }
        else
          route)
      (listOrEmpty routes);

  addDelegatedOverlayEgress =
    family: targetRole: interfaces: sourceNode: metric:
    delegatedOverlayEgress.add {
      inherit family sourceNode targetRole interfaces metric;
    };

  addOverlayExitIngress =
    family: interfaces:
    builtins.foldl'
      (current: sourceNode:
        overlayExitIngress.add {
          inherit family sourceNode;
          interfaces = current;
        })
      interfaces
      runtimeRoutedIPv6AccessNodeNames;

in
{
  markTargetPolicyDefaults =
    target:
    if !roleRequiresPolicyDefaults (target.role or null) then
      target
    else
      let
        effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
        interfaces = attrsOrEmpty (effective.interfaces or null);
        updatedInterfaces =
          builtins.mapAttrs
            (_: iface:
              let routes = attrsOrEmpty (iface.routes or null);
              in iface // {
                routes = routes // {
                  ipv4 = markDefaultPolicyOnly 4 (routes.ipv4 or [ ]);
                  ipv6 = markDefaultPolicyOnly 6 (routes.ipv6 or [ ]);
                };
              })
            interfaces;
      in
      target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; };

  add =
    family: sourceSet: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      targetWithoutOverlayDefaults = sanitizeOverlayDefaults family targetPath target;
      logicalNode = requireAttrs "${targetPath}.logicalNode" (targetWithoutOverlayDefaults.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      targetRole = targetWithoutOverlayDefaults.role or null;
      isSelfDefaultSource = hasAttr nodeName sourceSet;
      sourceSetForTarget =
        if isSelfDefaultSource && targetRole == "downstream-selector" then builtins.removeAttrs sourceSet [ nodeName ] else sourceSet;
      delegatedSourceNodes =
        builtins.filter
          (sourceNode: delegatedSourceUsesOverlayEgress family sourceNode)
          (sortedNames sourceSetForTarget);
      withDelegatedOverlayEgress =
        if delegatedSourceNodes == [ ] then
          targetWithoutOverlayDefaults
        else
          let
            targetView = targetInterfaces targetPath targetWithoutOverlayDefaults;
            interfaces =
              builtins.foldl'
                (current: sourceNode: addDelegatedOverlayEgress family targetRole current sourceNode 50)
                targetView.interfaces
                delegatedSourceNodes;
          in
          targetWithoutOverlayDefaults // { effectiveRuntimeRealization = targetView.effective // { inherit interfaces; }; };
      withOverlayExitIngress =
        if family == 6 && targetRole == "upstream-selector" && runtimeRoutedIPv6AccessNodeNames != [ ] then
          let
            targetView = targetInterfaces targetPath withDelegatedOverlayEgress;
            interfaces = addOverlayExitIngress family targetView.interfaces;
          in
          withDelegatedOverlayEgress // { effectiveRuntimeRealization = targetView.effective // { inherit interfaces; }; }
        else
          withDelegatedOverlayEgress;
      candidatePaths = builtins.filter (preferredFirstHopMatchesSource family) (sortedCandidatePaths family sourceSetForTarget nodeName);
    in
    if (isSelfDefaultSource && targetRole != "downstream-selector") || candidatePaths == [ ] then
      withOverlayExitIngress
    else
      let
        targetView = targetInterfaces targetPath withOverlayExitIngress;
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
            firstStepLane = attrsOrEmpty (firstStep.laneMeta or null);
            accessNodeName = firstStepLane.access or null;
            uplinkName = firstStepLane.uplink or null;
            delegatedWANFirstHop = isNonEmptyString accessNodeName && isDelegatedIPv6AccessNode accessNodeName && isNonEmptyString uplinkName && !hasAttr uplinkName siteOverlayNameSet;
            nonDelegatedOverlayFirstHop = isNonEmptyString accessNodeName && !isDelegatedIPv6AccessNode accessNodeName && isNonEmptyString uplinkName && hasAttr uplinkName siteOverlayNameSet;
            interfacesWithDelegatedOverlayEgress =
              if delegatedSourceUsesOverlayEgress family candidate.sourceNode then
                addDelegatedOverlayEgress family targetRole state.interfaces candidate.sourceNode (50 + (idx * 100))
              else
                state.interfaces;
          in
          if interfaceName == null || delegatedWANFirstHop || nonDelegatedOverlayFirstHop then
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
                // (if (firstStep.laneMeta or { }) != { } then { lane = firstStep.laneMeta; } else { })
                // (if roleRequiresPolicyDefaults targetRole then { policyOnly = true; } else { });
              updated = existing ++ [ defaultRoute ];
              updatedIface = iface // { routes = routes // (if family == 4 then { ipv4 = updated; } else { ipv6 = updated; }); };
            in
            { index = idx + 1; interfaces = interfacesWithDelegatedOverlayEgress // { ${interfaceName} = updatedIface; }; };
        updated =
          builtins.foldl'
            updateForCandidate
            { index = 0; interfaces = sanitized; }
            (builtins.filter (candidate: candidate.steps != [ ]) candidatePaths);
      in
      target // { effectiveRuntimeRealization = targetView.effective // { interfaces = updated.interfaces; }; };
}
