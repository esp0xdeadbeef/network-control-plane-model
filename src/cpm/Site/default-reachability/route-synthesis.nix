{
  helpers,
  common,
  ipam,
  sitePath,
  siteOverlayNameSet,
  overlayExitPeerSiteByName,
  runtimeTargetNames,
  runtimeTargetsWithWANDefaults,
  transitEndpointAddressesByNode,
  sortedCandidatePaths,
  preferredFirstHopMatchesSource,
  explicitDefaultSourceSet4,
  explicitDefaultSourceSet6,
  delegatedSourceUsesOverlayEgress,
  isDelegatedIPv6AccessNode,
  runtimeRoutedIPv6AccessNodeNames,
  runtimeRoutedIPv6PrefixesByAccessNode,
  routeHelpers,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs requireString sortedNames;
  inherit (common)
    attrsOrEmpty
    buildInternalDefaultRoute
    listOrEmpty
    routeMatchesDefault
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
    inherit helpers common siteOverlayNameSet overlayExitPeerSiteByName;
  };
  overlayExitIngress = import ./overlay-exit-ingress.nix {
    inherit helpers common ipam siteOverlayNameSet;
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
  runtimeRoutedPrefixRoutes = import ./runtime-routed-prefix-routes.nix {
    inherit
      helpers
      common
      sitePath
      sortedCandidatePaths
      preferredFirstHopMatchesSource
      routeHelpers
      runtimeRoutedIPv6PrefixesByAccessNode
      ;
  };
  inherit (defaultRouteSanitizer)
    sanitizeDefaultRoutes
    sanitizeDefaultRoutesForInterface
    sanitizeOverlayDefaults
    ;

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

  markTargetPolicyDefaults = target:
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
      delegatedSourceNodes =
        builtins.filter
          (sourceNode: delegatedSourceUsesOverlayEgress family sourceNode)
          (sortedNames sourceSetForTarget);
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
                    targetRole = targetRole;
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
      targetWithOverlayExitIngress =
        if family == 6 && targetRole == "upstream-selector" && runtimeRoutedIPv6AccessNodeNames != [ ] then
          let
            targetView = targetInterfaces targetPath targetWithDelegatedOverlayEgress;
            interfacesWithOverlayExitIngress =
              builtins.foldl'
                (interfaces: sourceNode:
                  overlayExitIngress.add {
                    family = family;
                    sourceNode = sourceNode;
                    interfaces = interfaces;
                  })
                targetView.interfaces
                runtimeRoutedIPv6AccessNodeNames;
          in
          targetWithDelegatedOverlayEgress
          // {
            effectiveRuntimeRealization = targetView.effective // { interfaces = interfacesWithOverlayExitIngress; };
          }
        else
          targetWithDelegatedOverlayEgress;
      candidatePaths = builtins.filter (preferredFirstHopMatchesSource family) (sortedCandidatePaths family sourceSetForTarget nodeName);
    in
    if (isSelfDefaultSource && targetRole != "downstream-selector") || candidatePaths == [ ] then
      targetWithOverlayExitIngress
    else
      let
        targetView = targetInterfaces targetPath targetWithOverlayExitIngress;
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
              if family == 6 && delegatedSourceUsesOverlayEgress family candidate.sourceNode then
                delegatedOverlayEgress.add {
                  family = family;
                  sourceNode = candidate.sourceNode;
                  metric = 50 + (idx * 100);
                  targetRole = targetRole;
                  interfaces = state.interfaces;
                }
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
                // (
                  if targetRole == "policy" || targetRole == "upstream-selector" || targetRole == "downstream-selector" then
                    { policyOnly = true; }
                  else
                    { }
                );
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
      target5 = runtimeRoutedPrefixRoutes.add targetName target4;
      target6 = explicitDefaultPreservation.restore { inherit targetName; originalTarget = target0; resolvedTarget = target5; };
      target7 = markTargetPolicyDefaults target6;
    in
    { name = targetName; value = target7; };

in
{
  runtimeTargetsWithSynthesizedDefaults = builtins.listToAttrs (builtins.map buildTarget runtimeTargetNames);
}
