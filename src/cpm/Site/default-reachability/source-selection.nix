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
    attrsOrEmpty
    defaultDst
    listContains
    listOrEmpty
    makeStringSet
    routesContainDefault
    uniqueStrings
    ;

  runtimeRoutedIPv6PrefixesForTenant =
    tenantName:
    let
      tenant = attrsOrEmpty (siteAttrs.tenants.${tenantName} or null);
      resolvedRoutedPrefixes = attrsOrEmpty (siteAttrs.routedPrefixesByTenant or null);
      ownership = attrsOrEmpty (siteAttrs.ownership or null);
      ownershipPrefixes = listOrEmpty (ownership.prefixes or null);
      tenantOwnershipPrefixes =
        builtins.filter
          (prefix: (attrsOrEmpty prefix).name or null == tenantName)
          ownershipPrefixes;
      routedEntries =
        (listOrEmpty (tenant.routedPrefixes or null))
        ++ (listOrEmpty (resolvedRoutedPrefixes.${tenantName} or null))
        ++ builtins.concatLists (builtins.map (prefix: listOrEmpty ((attrsOrEmpty prefix).routedPrefixes or null)) tenantOwnershipPrefixes);
    in
    builtins.filter
      (routed:
        (routed.family or null) == "ipv6"
        && ((routed.allocation or null) == "runtime" || (routed.source or null) == "inventory-routed-prefix"))
      routedEntries;

  ownsRuntimeRoutedIPv6Prefix =
    tenantName:
    builtins.any
      (_: true)
      (runtimeRoutedIPv6PrefixesForTenant tenantName);

  isRuntimeRoutedIPv6AccessNode =
    accessNodeName:
    hasAttr accessNodeName runtimeTargetsWithWANDefaultsByNode
    && (
      let
        target = runtimeTargetsWithWANDefaultsByNode.${accessNodeName}.target;
        networks = attrsOrEmpty (target.networks or null);
      in
      builtins.any
        (networkName:
          let network = attrsOrEmpty networks.${networkName};
          in
          (network.kind or null) == "tenant"
          && (
            ownsRuntimeRoutedIPv6Prefix networkName
            || builtins.any
              (routed:
                (routed.family or null) == "ipv6"
                && ((routed.allocation or null) == "runtime" || (routed.source or null) == "inventory-routed-prefix"))
              (listOrEmpty (network.routedPrefixes or null))
          ))
        (sortedNames networks)
    );

  isDelegatedIPv6AccessNode = isRuntimeRoutedIPv6AccessNode;

  runtimeRoutedIPv6PrefixesForAccessNode =
    accessNodeName:
    if !hasAttr accessNodeName runtimeTargetsWithWANDefaultsByNode then
      [ ]
    else
      let
        target = runtimeTargetsWithWANDefaultsByNode.${accessNodeName}.target;
        networks = attrsOrEmpty (target.networks or null);
      in
      builtins.concatLists (
        builtins.map
          (networkName:
            let
              network = attrsOrEmpty networks.${networkName};
              networkPrefixes =
                builtins.filter
                  (routed:
                    (routed.family or null) == "ipv6"
                    && ((routed.allocation or null) == "runtime" || (routed.source or null) == "inventory-routed-prefix"))
                  (listOrEmpty (network.routedPrefixes or null));
            in
            if (network.kind or null) != "tenant" then
              [ ]
            else
              runtimeRoutedIPv6PrefixesForTenant networkName ++ networkPrefixes)
          (sortedNames networks)
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

  overlayDefaultSourceNodeNamesForFamily =
    family:
    builtins.filter
      (nodeName:
        let targetEntry = runtimeTargetsWithWANDefaultsByNode.${nodeName};
        in targetHasOverlayDefaultSourceForFamily family targetEntry.targetName targetEntry.target)
      (sortedNames runtimeTargetsWithWANDefaultsByNode);

  delegatedSourceUsesOverlayEgress =
    family: accessNodeName:
    isDelegatedIPv6AccessNode accessNodeName
    && overlayDefaultSourceNodeNamesForFamily family != [ ];

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
      firstStepLane = attrsOrEmpty (if firstStep == null then null else firstStep.laneMeta or null);
      uplinkName = firstStepLane.uplink or null;
      accessNodeName = firstStepLane.access or null;
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
    delegatedSourceUsesOverlayEgress
    preferredFirstHopMatchesSource
    ;
  runtimeRoutedIPv6AccessNodeNames =
    builtins.filter isRuntimeRoutedIPv6AccessNode (sortedNames runtimeTargetsWithWANDefaultsByNode);
  runtimeRoutedIPv6PrefixesByAccessNode = builtins.listToAttrs (
    builtins.map
      (accessNodeName: {
        name = accessNodeName;
        value = runtimeRoutedIPv6PrefixesForAccessNode accessNodeName;
      })
      (builtins.filter isRuntimeRoutedIPv6AccessNode (sortedNames runtimeTargetsWithWANDefaultsByNode))
  );
  inherit
    targetHasDefaultReachabilityForFamily
    ;
}
