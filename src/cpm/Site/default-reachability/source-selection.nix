{
  helpers,
  common,
  sitePath,
  siteAttrs,
  siteOverlayNameSet,
  runtimeTargetsWithWANDefaultsByNode,
  selectedUplinkNamesForTarget,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs sortedNames;
  inherit (common)
    accessNodeNameFromAdjacencyId
    attrsOrEmpty
    defaultDst
    listContains
    listOrEmpty
    makeStringSet
    routesContainDefault
    uniqueStrings
    uplinkNameFromAdjacencyId
    ;

  isDelegatedIPv6AccessNode =
    accessNodeName:
    hasAttr accessNodeName runtimeTargetsWithWANDefaultsByNode
    && (
      let
        target = runtimeTargetsWithWANDefaultsByNode.${accessNodeName}.target;
        externalValidation = attrsOrEmpty (target.externalValidation or null);
        advertisements = attrsOrEmpty (target.advertisements or null);
        ipv6Ra = attrsOrEmpty (advertisements.ipv6Ra or null);
        networks = attrsOrEmpty (target.networks or null);
        siteTenants = attrsOrEmpty (siteAttrs.tenants or null);
        siteIPv6PD = attrsOrEmpty ((attrsOrEmpty (siteAttrs.ipv6 or null)).pd or null);
        hasRuntimePrefixAdvertisement =
          builtins.any
            (raName: !(builtins.isList ((attrsOrEmpty ipv6Ra.${raName}).prefixes or null)))
            (sortedNames ipv6Ra);
        hasSlaacPDNetwork =
          siteIPv6PD != { }
          && builtins.any
            (networkName:
              let
                network = attrsOrEmpty networks.${networkName};
                tenantIPv6 = attrsOrEmpty ((attrsOrEmpty (siteTenants.${networkName} or null)).ipv6 or null);
              in
              (network.kind or null) == "tenant" && (tenantIPv6.mode or null) == "slaac")
            (sortedNames networks);
      in
      (externalValidation.delegatedIPv6Prefix or false) == true
      || isNonEmptyString (externalValidation.delegatedPrefixSecretName or null)
      || hasRuntimePrefixAdvertisement
      || hasSlaacPDNetwork
    );

  defaultRouteCountsAsSource = family: route:
    let
      lane = attrsOrEmpty (route.lane or null);
      laneUplink = lane.uplink or null;
      laneAccess = lane.access or null;
      isOverlayLaneDefault = isNonEmptyString laneUplink && hasAttr laneUplink siteOverlayNameSet;
      delegatedAccess = isNonEmptyString laneAccess && isDelegatedIPv6AccessNode laneAccess;
    in
    routesContainDefault family [ route ] && (!isOverlayLaneDefault || delegatedAccess);

  targetHasDefaultReachabilityForFamily = family: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
      interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
    in
    builtins.any
      (ifName:
        let
          iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
          routes = attrsOrEmpty (iface.routes or null);
        in
        builtins.any
          (defaultRouteCountsAsSource family)
          (if family == 4 then routes.ipv4 or [ ] else routes.ipv6 or [ ]))
      (sortedNames interfaces);

  targetHasOverlayDefaultSourceForFamily = family: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
      interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
    in
    builtins.any
      (ifName:
        let
          iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
          upstream = iface.upstream or null;
          wan = attrsOrEmpty (iface.wan or null);
        in
        (iface.sourceKind or null) == "wan"
        && isNonEmptyString upstream
        && hasAttr upstream siteOverlayNameSet
        && listContains (defaultDst family) (if family == 4 then wan.ipv4 or [ ] else wan.ipv6 or [ ]))
      (sortedNames interfaces);

  defaultSourceUplinkNamesForFamily = family: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
      interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
    in
    uniqueStrings (
      builtins.map
        (ifName:
          let
            iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
            routes = attrsOrEmpty (iface.routes or null);
            upstream = iface.upstream or null;
          in
          if
            (iface.sourceKind or null) == "wan"
            && isNonEmptyString upstream
            && !hasAttr upstream siteOverlayNameSet
            && routesContainDefault family (if family == 4 then routes.ipv4 or [ ] else routes.ipv6 or [ ])
          then
            upstream
          else
            null)
        (sortedNames interfaces)
    );

  explicitDefaultSourceNodeNamesForFamily = family:
    let
      nodesWithExplicitDefaults =
        builtins.filter
          (nodeName:
            let targetEntry = runtimeTargetsWithWANDefaultsByNode.${nodeName};
            in targetHasDefaultReachabilityForFamily family targetEntry.targetName targetEntry.target)
          (sortedNames runtimeTargetsWithWANDefaultsByNode);
      overlayDefaultSourceNodes =
        builtins.filter
          (nodeName:
            let targetEntry = runtimeTargetsWithWANDefaultsByNode.${nodeName};
            in targetHasOverlayDefaultSourceForFamily family targetEntry.targetName targetEntry.target)
          (sortedNames runtimeTargetsWithWANDefaultsByNode);
    in
    uniqueStrings (nodesWithExplicitDefaults ++ overlayDefaultSourceNodes);

  preferredFirstHopMatchesSource =
    family: candidate:
    let
      sourceEntry =
        if hasAttr candidate.sourceNode runtimeTargetsWithWANDefaultsByNode then
          runtimeTargetsWithWANDefaultsByNode.${candidate.sourceNode}
        else
          null;
      selectedUplinkNames =
        if sourceEntry == null then
          [ ]
        else
          uniqueStrings (
            builtins.filter
              (uplinkName: !hasAttr uplinkName siteOverlayNameSet)
              (selectedUplinkNamesForTarget sourceEntry.target)
            ++ defaultSourceUplinkNamesForFamily family sourceEntry.targetName sourceEntry.target
          );
      firstStep = if builtins.length candidate.steps == 0 then null else builtins.elemAt candidate.steps 0;
      uplinkName = if firstStep == null then null else uplinkNameFromAdjacencyId firstStep.adjacencyId;
      accessNodeName = if firstStep == null then null else accessNodeNameFromAdjacencyId firstStep.adjacencyId;
      delegatedAccess = isNonEmptyString accessNodeName && isDelegatedIPv6AccessNode accessNodeName;
    in
    if firstStep == null || uplinkName == null then
      true
    else if delegatedAccess then
      hasAttr uplinkName siteOverlayNameSet
    else
      listContains uplinkName selectedUplinkNames;

in
{
  explicitDefaultSourceSet4 = makeStringSet (explicitDefaultSourceNodeNamesForFamily 4);
  explicitDefaultSourceSet6 = makeStringSet (explicitDefaultSourceNodeNamesForFamily 6);
  inherit
    isDelegatedIPv6AccessNode
    preferredFirstHopMatchesSource
    targetHasDefaultReachabilityForFamily
    ;
}
