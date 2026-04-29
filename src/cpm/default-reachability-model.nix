{ helpers }:

{ sitePath, siteAttrs, transit, runtimeTargets }:

let
  inherit (helpers)
    hasAttr
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    sortedNames
    ;

  attrsOrEmpty = value:
    if builtins.isAttrs value then
      value
    else
      { };

  listOrEmpty = value:
    if builtins.isList value then
      value
    else
      [ ];

  makeStringSet = values:
    builtins.listToAttrs (
      builtins.map
        (value: {
          name = value;
          value = true;
        })
        values
    );

  uniqueStrings =
    values:
    sortedNames (
      builtins.listToAttrs (
        builtins.map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter isNonEmptyString values)
      )
    );

  uplinkNameFromAdjacencyId =
    adjacencyId:
    let
      marker = "--uplink-";
      parts = builtins.filter isNonEmptyString (builtins.split marker adjacencyId);
    in
    if builtins.length parts < 2 then
      null
    else
      builtins.elemAt parts ((builtins.length parts) - 1);

  accessNodeNameFromAdjacencyId =
    adjacencyId:
    let
      match = builtins.match ".*--access-(.+)--uplink-.*" adjacencyId;
    in
    if match == null then null else builtins.elemAt match 0;

  overlayNameFromInterfaceName =
    interfaceName:
    let
      match = builtins.match "overlay-(.+)" interfaceName;
    in
    if match == null then null else builtins.elemAt match 0;

  defaultDst = family:
    if family == 4 then
      "0.0.0.0/0"
    else
      "::/0";

  routeMatchesDefault = family: route:
    builtins.isAttrs route
    && (route.dst or null) == defaultDst family;

  routesContainDefault = family: routes:
    builtins.any
      (route: routeMatchesDefault family route)
      (listOrEmpty routes);

  stripDefaultRoutes = family: routes:
    builtins.filter
      (route: !(routeMatchesDefault family route))
      (listOrEmpty routes);

  listContains = expected: values:
    builtins.any
      (value: value == expected)
      (listOrEmpty values);

  runtimeTargetNames = sortedNames runtimeTargets;

  runtimeTargetsByNode =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            targetPath = "${sitePath}.runtimeTargets.${targetName}";
            target = requireAttrs targetPath runtimeTargets.${targetName};
            logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
            nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
          in
          {
            name = nodeName;
            value = {
              inherit targetName target;
            };
          })
        runtimeTargetNames
    );

  forwardingSemantics =
    attrsOrEmpty (siteAttrs.forwardingSemantics or null);

  forwardingSemanticsNodes =
    attrsOrEmpty (forwardingSemantics.nodes or null);

  siteEgressIntent =
    attrsOrEmpty (siteAttrs.egressIntent or null);

  transportAttrs =
    attrsOrEmpty (siteAttrs.transport or null);

  siteOverlayNames =
    uniqueStrings (
      sortedNames (attrsOrEmpty (siteAttrs.overlays or null))
      ++ builtins.map
        (overlay: overlay.name or null)
        (listOrEmpty (transportAttrs.overlays or null))
      ++ builtins.concatLists (
        builtins.map
          (targetName:
            let
              target = requireAttrs "${sitePath}.runtimeTargets.${targetName}" runtimeTargets.${targetName};
              effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
              interfaces = attrsOrEmpty (effective.interfaces or null);
            in
            builtins.map
              (ifName:
                let
                  iface = attrsOrEmpty interfaces.${ifName};
                in
                if (iface.sourceKind or null) == "overlay" then
                  overlayNameFromInterfaceName ifName
                else
                  null)
              (sortedNames interfaces))
          runtimeTargetNames
      )
    );

  siteOverlayNameSet = makeStringSet siteOverlayNames;

  exitNodeNamesFromSite =
    if builtins.isList (siteEgressIntent.exitNodeNames or null) then
      builtins.filter isNonEmptyString siteEgressIntent.exitNodeNames
    else
      [ ];

  exitNodeNamesFromForwardingSemantics =
    builtins.filter
      (nodeName:
        let
          nodeSemantics = attrsOrEmpty forwardingSemanticsNodes.${nodeName};
          egressIntent = attrsOrEmpty (nodeSemantics.egressIntent or null);
        in
        (egressIntent.exit or false) == true)
      (sortedNames forwardingSemanticsNodes);

  exitNodeNamesFromRuntimeTargets =
    builtins.filter
      (nodeName:
        let
          target = runtimeTargetsByNode.${nodeName}.target;
          egressIntent = attrsOrEmpty (target.egressIntent or null);
        in
        (egressIntent.exit or false) == true)
      (sortedNames runtimeTargetsByNode);

  exitNodeSet =
    makeStringSet (
      exitNodeNamesFromSite
      ++ exitNodeNamesFromForwardingSemantics
      ++ exitNodeNamesFromRuntimeTargets
    );

  buildWANDefaultRoute = family: {
    dst = defaultDst family;
    intent = {
      kind = "default-reachability";
      source = "wan";
    };
    proto = "upstream";
  };

  selectedUplinkNamesForTarget = target:
    let
      egressIntent = attrsOrEmpty (target.egressIntent or null);
    in
    (if builtins.isList (egressIntent.uplinks or null) then
      builtins.filter isNonEmptyString egressIntent.uplinks
    else
      [ ])
    ++
    (if builtins.isList (egressIntent.wanInterfaces or null) then
      builtins.filter isNonEmptyString egressIntent.wanInterfaces
    else
      [ ]);

  augmentWANInterfaceRoutes = selectedUplinkSet: selectedUplinkNames: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      hostUplink = attrsOrEmpty (iface.hostUplink or null);
      wan = attrsOrEmpty (iface.wan or null);
      upstream = iface.upstream or null;
      isOverlayTransportUplink =
        isNonEmptyString upstream && hasAttr upstream siteOverlayNameSet;

      selected =
        selectedUplinkNames == [ ]
        || (isNonEmptyString upstream && hasAttr upstream selectedUplinkSet);

      ipv4Routes = listOrEmpty (routes.ipv4 or null);
      ipv6Routes = listOrEmpty (routes.ipv6 or null);

      wantsIPv4Default =
        !isOverlayTransportUplink
        && selected
        && (
          builtins.isAttrs (hostUplink.ipv4 or null)
          || listContains "0.0.0.0/0" (wan.ipv4 or null)
        );

      wantsIPv6Default =
        !isOverlayTransportUplink
        && selected
        && (
          builtins.isAttrs (hostUplink.ipv6 or null)
          || listContains "::/0" (wan.ipv6 or null)
        );

      updatedIPv4Routes =
        if isOverlayTransportUplink then
          stripDefaultRoutes 4 ipv4Routes
        else if wantsIPv4Default && !routesContainDefault 4 ipv4Routes then
          ipv4Routes ++ [ (buildWANDefaultRoute 4) ]
        else
          ipv4Routes;

      updatedIPv6Routes =
        if isOverlayTransportUplink then
          stripDefaultRoutes 6 ipv6Routes
        else if wantsIPv6Default && !routesContainDefault 6 ipv6Routes then
          ipv6Routes ++ [ (buildWANDefaultRoute 6) ]
        else
          ipv6Routes;
    in
    iface
    // {
      routes =
        routes
        // {
          ipv4 = updatedIPv4Routes;
          ipv6 = updatedIPv6Routes;
        };
    };

  augmentWANRoutesForTarget = targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      selectedUplinkNames = selectedUplinkNamesForTarget target;
      selectedUplinkSet = makeStringSet selectedUplinkNames;
      exitEnabled = hasAttr nodeName exitNodeSet;
    in
    if !exitEnabled then
      target
    else
      let
        effective =
          requireAttrs
            "${targetPath}.effectiveRuntimeRealization"
            (target.effectiveRuntimeRealization or null);
        interfaces =
          requireAttrs
            "${targetPath}.effectiveRuntimeRealization.interfaces"
            (effective.interfaces or null);

        updatedInterfaces =
          builtins.listToAttrs (
            builtins.map
              (ifName:
                let
                  iface =
                    requireAttrs
                      "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}"
                      interfaces.${ifName};
                in
                {
                  name = ifName;
                  value =
                    if (iface.sourceKind or null) == "wan" then
                      augmentWANInterfaceRoutes selectedUplinkSet selectedUplinkNames iface
                    else
                      iface;
                })
              (sortedNames interfaces)
          );
      in
      target
      // {
        effectiveRuntimeRealization =
          effective
          // {
            interfaces = updatedInterfaces;
          };
      };

  runtimeTargetsWithWANDefaults =
    builtins.listToAttrs (
      builtins.map
        (targetName: {
          name = targetName;
          value = augmentWANRoutesForTarget targetName runtimeTargets.${targetName};
        })
        runtimeTargetNames
    );

  runtimeTargetsWithWANDefaultsByNode =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            targetPath = "${sitePath}.runtimeTargets.${targetName}";
            target = requireAttrs targetPath runtimeTargetsWithWANDefaults.${targetName};
            logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
            nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
          in
          {
            name = nodeName;
            value = {
              inherit targetName target;
            };
          })
        runtimeTargetNames
    );

  targetHasDefaultReachabilityForFamily = family: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization"
          (target.effectiveRuntimeRealization or null);
      interfaces =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization.interfaces"
          (effective.interfaces or null);
    in
    builtins.any
      (ifName:
        let
          iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
          routes = attrsOrEmpty (iface.routes or null);
        in
        routesContainDefault family (
          if family == 4 then
            routes.ipv4 or [ ]
          else
            routes.ipv6 or [ ]
        ))
      (sortedNames interfaces);

  targetHasOverlayDefaultSourceForFamily = family: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization"
          (target.effectiveRuntimeRealization or null);
      interfaces =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization.interfaces"
          (effective.interfaces or null);
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
        && listContains (defaultDst family) (
          if family == 4 then wan.ipv4 or [ ] else wan.ipv6 or [ ]
        ))
      (sortedNames interfaces);

  defaultSourceUplinkNamesForFamily = family: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization"
          (target.effectiveRuntimeRealization or null);
      interfaces =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization.interfaces"
          (effective.interfaces or null);
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
            && routesContainDefault family (
              if family == 4 then
                routes.ipv4 or [ ]
              else
                routes.ipv6 or [ ]
            )
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
            let
              targetEntry = runtimeTargetsWithWANDefaultsByNode.${nodeName};
            in
            targetHasDefaultReachabilityForFamily family targetEntry.targetName targetEntry.target)
          (sortedNames runtimeTargetsWithWANDefaultsByNode);
      overlayDefaultSourceNodes =
        builtins.filter
          (nodeName:
            let
              targetEntry = runtimeTargetsWithWANDefaultsByNode.${nodeName};
            in
            targetHasOverlayDefaultSourceForFamily family targetEntry.targetName targetEntry.target)
          (sortedNames runtimeTargetsWithWANDefaultsByNode);
    in
    uniqueStrings (
      (
        if sortedNames exitNodeSet == [ ] then
          nodesWithExplicitDefaults
        else
          builtins.filter
            (nodeName: hasAttr nodeName exitNodeSet)
            nodesWithExplicitDefaults
      )
      ++ overlayDefaultSourceNodes
    );

  explicitDefaultSourceSet4 =
    makeStringSet (explicitDefaultSourceNodeNamesForFamily 4);

  explicitDefaultSourceSet6 =
    makeStringSet (explicitDefaultSourceNodeNamesForFamily 6);

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

      firstStep =
        if builtins.length candidate.steps == 0 then
          null
        else
          builtins.elemAt candidate.steps 0;

      uplinkName =
        if firstStep == null then
          null
        else
          uplinkNameFromAdjacencyId firstStep.adjacencyId;

      accessNodeName =
        if firstStep == null then
          null
        else
          accessNodeNameFromAdjacencyId firstStep.adjacencyId;

      delegatedIPv6Access =
        family == 6
        && isNonEmptyString accessNodeName
        && isDelegatedIPv6AccessNode accessNodeName;
    in
    if firstStep == null || uplinkName == null then
      true
    else if delegatedIPv6Access then
      hasAttr uplinkName siteOverlayNameSet
    else
      listContains uplinkName selectedUplinkNames;

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
        siteIPv6 = attrsOrEmpty (siteAttrs.ipv6 or null);
        siteIPv6PD = attrsOrEmpty (siteIPv6.pd or null);
        hasRuntimePrefixAdvertisement =
          builtins.any
            (raName:
              let
                ra = attrsOrEmpty ipv6Ra.${raName};
              in
              !(builtins.isList (ra.prefixes or null)))
            (sortedNames ipv6Ra);
        hasSlaacPDNetwork =
          siteIPv6PD != { }
          &&
          builtins.any
            (networkName:
              let
                network = attrsOrEmpty networks.${networkName};
                tenant = attrsOrEmpty (siteTenants.${networkName} or null);
                tenantIPv6 = attrsOrEmpty (tenant.ipv6 or null);
              in
              (network.kind or null) == "tenant"
              && (tenantIPv6.mode or null) == "slaac")
            (sortedNames networks);
      in
      (externalValidation.delegatedIPv6Prefix or false) == true
      || isNonEmptyString (externalValidation.delegatedPrefixSecretName or null)
      || hasRuntimePrefixAdvertisement
      || hasSlaacPDNetwork
    );

  addNeighbor = acc: nodeName: neighborRecord:
    let
      existing =
        if hasAttr nodeName acc then
          acc.${nodeName}
        else
          [ ];
    in
    acc
    // {
      ${nodeName} = existing ++ [ neighborRecord ];
    };

  neighborMap =
    builtins.foldl'
      (acc: adjacency:
        let
          adjacencyId = requireString "${sitePath}.transit.adjacencies[*].id" (adjacency.id or null);
          endpoints = requireList "${sitePath}.transit.adjacencies[*].endpoints" (adjacency.endpoints or null);

          left = builtins.elemAt endpoints 0;
          right = builtins.elemAt endpoints 1;

          leftNode = requireString "${sitePath}.transit.adjacencies[*].endpoints[0].unit" (left.unit or null);
          rightNode = requireString "${sitePath}.transit.adjacencies[*].endpoints[1].unit" (right.unit or null);

          leftLocal = attrsOrEmpty (left.local or null);
          rightLocal = attrsOrEmpty (right.local or null);

          acc1 =
            addNeighbor acc leftNode {
              adjacencyId = adjacencyId;
              neighbor = rightNode;
              via4 = rightLocal.ipv4 or null;
              via6 = rightLocal.ipv6 or null;
            };
        in
        addNeighbor acc1 rightNode {
          adjacencyId = adjacencyId;
          neighbor = leftNode;
          via4 = leftLocal.ipv4 or null;
          via6 = leftLocal.ipv6 or null;
        })
      { }
      (listOrEmpty (transit.adjacencies or null));

  addTransitEndpointAddress =
    acc: nodeName: family: address:
    let
      existing =
        if hasAttr nodeName acc then
          acc.${nodeName}
        else
          { ipv4 = [ ]; ipv6 = [ ]; };
      familyValues =
        if family == 4 then
          uniqueStrings (existing.ipv4 ++ [ address ])
        else
          existing.ipv4;
      familyValues6 =
        if family == 6 then
          uniqueStrings (existing.ipv6 ++ [ address ])
        else
          existing.ipv6;
    in
    acc
    // {
      ${nodeName} = {
        ipv4 = familyValues;
        ipv6 = familyValues6;
      };
    };

  transitEndpointAddressesByNode =
    builtins.foldl'
      (acc: adjacency:
        let
          endpoints =
            requireList "${sitePath}.transit.adjacencies[*].endpoints" (adjacency.endpoints or null);
          applyEndpoint =
            state: endpoint:
            let
              nodeName =
                requireString "${sitePath}.transit.adjacencies[*].endpoints[*].unit" (endpoint.unit or null);
              local = attrsOrEmpty (endpoint.local or null);
              state4 =
                if isNonEmptyString (local.ipv4 or null) then
                  addTransitEndpointAddress state nodeName 4 local.ipv4
                else
                  state;
            in
            if isNonEmptyString (local.ipv6 or null) then
              addTransitEndpointAddress state4 nodeName 6 local.ipv6
            else
              state4;
        in
        builtins.foldl' applyEndpoint acc endpoints)
      { }
      (listOrEmpty (transit.adjacencies or null));

  findCandidatePaths = family: sourceSet: nodeName: visited:
    if hasAttr nodeName sourceSet then
      [
        {
          sourceNode = nodeName;
          steps = [ ];
        }
      ]
    else
      let
        neighbors =
          if hasAttr nodeName neighborMap then
            neighborMap.${nodeName}
          else
            [ ];
      in
      builtins.concatLists (
        builtins.map
          (neighbor:
            let
              neighborNode = neighbor.neighbor;
              familyVia =
                if family == 4 then
                  neighbor.via4 or null
                else
                  neighbor.via6 or null;
            in
            if hasAttr neighborNode visited || !isNonEmptyString familyVia then
              [ ]
            else
              builtins.map
                (subPath:
                  {
                    sourceNode = subPath.sourceNode;
                    steps =
                      [
                        {
                          adjacencyId = neighbor.adjacencyId;
                          via = familyVia;
                          nextHopNode = neighborNode;
                        }
                      ]
                      ++ subPath.steps;
                  })
                (findCandidatePaths family sourceSet neighborNode (visited // { ${nodeName} = true; })))
          neighbors
      );

  compareCandidatePaths =
    left: right:
    if builtins.length left.steps < builtins.length right.steps then
      true
    else if builtins.length left.steps > builtins.length right.steps then
      false
    else
      left.sourceNode < right.sourceNode;

  sortedCandidatePaths = family: sourceSet: nodeName:
    builtins.sort compareCandidatePaths (findCandidatePaths family sourceSet nodeName { });

  findInterfaceNameForAdjacency = targetName: target: adjacencyId:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization"
          (target.effectiveRuntimeRealization or null);
      interfaces =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization.interfaces"
          (effective.interfaces or null);

      matchingNames =
        builtins.filter
          (ifName:
            let
              iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
              backingRef = attrsOrEmpty (iface.backingRef or null);
            in
            (backingRef.id or null) == adjacencyId)
          (sortedNames interfaces);
    in
    if matchingNames == [ ] then
      null
    else
      builtins.elemAt matchingNames 0;

  buildInternalDefaultRoute =
    family: sourceNode: via: metric:
    {
      dst = defaultDst family;
      intent = {
        kind = "default-reachability";
        source = "explicit-exit";
        exitNode = sourceNode;
      };
      proto = "internal";
      inherit metric;
    }
    // {
      ${if family == 4 then "via4" else "via6"} = via;
    };

  buildInternalEndpointRoute =
    family: destination: destinationNode: via:
    {
      dst =
        if family == 4 then
          "${destination}/32"
        else
          "${destination}/128";
      intent = {
        kind = "internal-reachability";
        source = "transit-endpoint";
        node = destinationNode;
      };
      proto = "internal";
    }
    // {
      ${if family == 4 then "via4" else "via6"} = via;
    };

  routeAlreadyPresent =
    family: routes: destination: via:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.dst or null)
          == (if family == 4 then "${destination}/32" else "${destination}/128")
        && (
          if family == 4 then
            (route.via4 or null) == via
          else
            (route.via6 or null) == via
        ))
      (listOrEmpty routes);

  interfaceHasDefaultForFamily =
    family: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
    in
    routesContainDefault family (
      if family == 4 then
        listOrEmpty (routes.ipv4 or null)
      else
        listOrEmpty (routes.ipv6 or null)
    );

  interfaceNameHasUplinkWanPreference =
    interfaceName:
    builtins.match ".*--uplink-wan$" interfaceName != null;

  interfaceNameTargetsDestination =
    interfaceName: destinationNode:
    builtins.match ".*(^|-)${destinationNode}(-|$).*" interfaceName != null;

  interfaceBackingKind =
    targetPath: interfaces: interfaceName:
    let
      iface =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
          interfaces.${interfaceName};
      backingRef = attrsOrEmpty (iface.backingRef or null);
    in
    backingRef.kind or null;

  synthesizeTransitEndpointRoutesForFamily = family: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      endpointNodes =
        builtins.filter
          (candidateNode:
            candidateNode != nodeName
            && hasAttr candidateNode transitEndpointAddressesByNode)
          (sortedNames transitEndpointAddressesByNode);
      effective =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization"
          (target.effectiveRuntimeRealization or null);
      interfaces =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization.interfaces"
          (effective.interfaces or null);

      updatedInterfaces =
        builtins.foldl'
          (currentInterfaces: destinationNode:
            let
              endpointAddresses = transitEndpointAddressesByNode.${destinationNode};
              familyAddresses =
                if family == 4 then
                  endpointAddresses.ipv4 or [ ]
                else
                  endpointAddresses.ipv6 or [ ];
              candidatePaths =
                builtins.filter
                  (preferredFirstHopMatchesSource family)
                  (sortedCandidatePaths family (makeStringSet [ destinationNode ]) nodeName);
              usableCandidates =
                builtins.filter (candidate: builtins.length candidate.steps > 1) candidatePaths;
            in
            if familyAddresses == [ ] || usableCandidates == [ ] then
              currentInterfaces
            else
              let
                candidateEntries =
                  builtins.map
                    (candidate:
                      let
                        firstStep = builtins.elemAt candidate.steps 0;
                      in
                      {
                        inherit candidate firstStep;
                        interfaceName = findInterfaceNameForAdjacency targetName target firstStep.adjacencyId;
                      })
                    usableCandidates;
                namedCandidates =
                  builtins.filter (entry: entry.interfaceName != null) candidateEntries;
                destinationScopedCandidates =
                  builtins.filter
                    (entry: interfaceNameTargetsDestination entry.interfaceName destinationNode)
                    namedCandidates;
                scopedCandidatesRaw =
                  if destinationScopedCandidates != [ ] then
                    destinationScopedCandidates
                  else
                    namedCandidates;
                preferredUplinkWanCandidates =
                  builtins.filter
                    (entry: interfaceNameHasUplinkWanPreference entry.interfaceName)
                    scopedCandidatesRaw;
                preferredOverlayCandidates =
                  builtins.filter
                    (
                      entry:
                      interfaceBackingKind targetPath interfaces entry.interfaceName == "overlay"
                    )
                    scopedCandidatesRaw;
                scopedCandidates =
                  if preferredUplinkWanCandidates != [ ] then
                    preferredUplinkWanCandidates
                  else if preferredOverlayCandidates != [ ] then
                    preferredOverlayCandidates
                  else
                    scopedCandidatesRaw;
                defaultBearingCandidates =
                  builtins.filter
                    (
                      entry:
                      interfaceHasDefaultForFamily family (
                        requireAttrs
                          "${targetPath}.effectiveRuntimeRealization.interfaces.${entry.interfaceName}"
                          interfaces.${entry.interfaceName}
                      )
                    )
                    scopedCandidates;
                chosenEntry =
                  if defaultBearingCandidates != [ ] then
                    builtins.elemAt defaultBearingCandidates 0
                  else if scopedCandidates != [ ] then
                    builtins.elemAt scopedCandidates 0
                  else
                    null;
              in
              if chosenEntry == null then
                currentInterfaces
              else
                let
                  firstStep = chosenEntry.firstStep;
                  interfaceName = chosenEntry.interfaceName;
                  iface =
                    requireAttrs
                      "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
                      currentInterfaces.${interfaceName};
                  routes = attrsOrEmpty (iface.routes or null);
                  existingFamilyRoutes =
                    if family == 4 then
                      listOrEmpty (routes.ipv4 or null)
                    else
                      listOrEmpty (routes.ipv6 or null);
                  updatedFamilyRoutes =
                    builtins.foldl'
                      (accRoutes: destination:
                        if routeAlreadyPresent family accRoutes destination firstStep.via then
                          accRoutes
                        else
                          accRoutes ++ [
                            (buildInternalEndpointRoute family destination destinationNode firstStep.via)
                          ])
                      existingFamilyRoutes
                      familyAddresses;
                  updatedIface =
                    iface
                    // {
                      routes =
                        routes
                        // (
                          if family == 4 then
                            { ipv4 = updatedFamilyRoutes; }
                          else
                            { ipv6 = updatedFamilyRoutes; }
                        );
                    };
                in
                currentInterfaces
                // {
                  ${interfaceName} = updatedIface;
                })
          interfaces
          endpointNodes;
    in
    target
    // {
      effectiveRuntimeRealization =
        effective
        // {
          interfaces = updatedInterfaces;
        };
    };

  synthesizeDefaultForFamily = family: sourceSet: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      candidatePaths =
        builtins.filter (preferredFirstHopMatchesSource family) (sortedCandidatePaths family sourceSet nodeName);
    in
    if hasAttr nodeName sourceSet || candidatePaths == [ ] then
      target
    else
      let
        effective =
          requireAttrs
            "${targetPath}.effectiveRuntimeRealization"
            (target.effectiveRuntimeRealization or null);
        interfaces =
          requireAttrs
            "${targetPath}.effectiveRuntimeRealization.interfaces"
            (effective.interfaces or null);

        sanitizedInterfaces =
          builtins.mapAttrs
            (
              interfaceName: iface:
              let
                routes = attrsOrEmpty (iface.routes or null);
              in
              iface
              // {
                routes =
                  routes
                  // (
                    if family == 4 then
                      {
                        ipv4 = stripDefaultRoutes 4 (routes.ipv4 or [ ]);
                      }
                    else
                      {
                        ipv6 = stripDefaultRoutes 6 (routes.ipv6 or [ ]);
                      }
                  );
              }
            )
            interfaces;

        updateForCandidate =
          state: candidate:
          let
            candidateIndex = state.index;
            firstStep = builtins.elemAt candidate.steps 0;
            interfaceName = findInterfaceNameForAdjacency targetName target firstStep.adjacencyId;
            accessNodeName = accessNodeNameFromAdjacencyId firstStep.adjacencyId;
            uplinkName = uplinkNameFromAdjacencyId firstStep.adjacencyId;
            delegatedIPv6WANFirstHop =
              family == 6
              && isNonEmptyString accessNodeName
              && isDelegatedIPv6AccessNode accessNodeName
              && isNonEmptyString uplinkName
              && !hasAttr uplinkName siteOverlayNameSet;
          in
          if interfaceName == null || delegatedIPv6WANFirstHop then
            state // { index = candidateIndex + 1; }
          else
            let
              iface =
                requireAttrs
                  "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
                  state.interfaces.${interfaceName};
              routes = attrsOrEmpty (iface.routes or null);
              existingFamilyRoutes =
                if family == 4 then
                  listOrEmpty (routes.ipv4 or null)
                else
                  listOrEmpty (routes.ipv6 or null);
              routeMetric = 100 + (candidateIndex * 100);
              newRoute = buildInternalDefaultRoute family candidate.sourceNode firstStep.via routeMetric;
              updatedFamilyRoutes = existingFamilyRoutes ++ [ newRoute ];
              updatedIface =
                iface
                // {
                  routes =
                    routes
                    // (
                      if family == 4 then
                        {
                          ipv4 = updatedFamilyRoutes;
                        }
                      else
                        {
                          ipv6 = updatedFamilyRoutes;
                        }
                    );
                };
            in
            {
              index = candidateIndex + 1;
              interfaces =
                state.interfaces
                // {
                  ${interfaceName} = updatedIface;
                };
            };

        updated =
          builtins.foldl'
            updateForCandidate
            {
              index = 0;
              interfaces = sanitizedInterfaces;
            }
            (builtins.filter (candidate: candidate.steps != [ ]) candidatePaths);
      in
      target
      // {
        effectiveRuntimeRealization =
          effective
          // {
            interfaces = updated.interfaces;
          };
      };

  runtimeTargetsWithSynthesizedDefaults =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target0 = runtimeTargetsWithWANDefaults.${targetName};
            target1 = synthesizeTransitEndpointRoutesForFamily 4 targetName target0;
            target2 = synthesizeTransitEndpointRoutesForFamily 6 targetName target1;
            target3 = synthesizeDefaultForFamily 4 explicitDefaultSourceSet4 targetName target2;
            target4 = synthesizeDefaultForFamily 6 explicitDefaultSourceSet6 targetName target3;
          in
          {
            name = targetName;
            value = target4;
          })
        runtimeTargetNames
    );

  targetHasAnyDefaultReachability = targetName: target:
    targetHasDefaultReachabilityForFamily 4 targetName target
    || targetHasDefaultReachabilityForFamily 6 targetName target;

  updatedRoutingAuthority =
    builtins.listToAttrs (
      builtins.map
        (targetName: {
          name = targetName;
          value = {
            defaultReachability =
              targetHasAnyDefaultReachability targetName runtimeTargetsWithSynthesizedDefaults.${targetName};
          };
        })
        runtimeTargetNames
    );

  runtimeTargetsWithUpdatedRoutingAuthority =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target = runtimeTargetsWithSynthesizedDefaults.${targetName};
            existingRoutingAuthority =
              if builtins.isAttrs (target.routingAuthority or null) then
                target.routingAuthority
              else
                { };
            resolvedRoutingAuthority =
              if hasAttr targetName updatedRoutingAuthority then
                let
                  candidate = updatedRoutingAuthority.${targetName};
                in
                if builtins.isAttrs candidate then
                  candidate
                else
                  { }
              else
                { };
            defaultReachability =
              if builtins.hasAttr "defaultReachability" resolvedRoutingAuthority then
                resolvedRoutingAuthority.defaultReachability
              else if builtins.hasAttr "defaultReachability" existingRoutingAuthority then
                existingRoutingAuthority.defaultReachability
              else if builtins.hasAttr "defaultReachability" target then
                target.defaultReachability
              else
                false;
          in
          {
            name = targetName;
            value =
              target
              // {
                routingAuthority =
                  existingRoutingAuthority
                  // resolvedRoutingAuthority
                  // {
                    inherit defaultReachability;
                  };
              };
          })
        runtimeTargetNames
    );

  defaultReachabilityByNode =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target = runtimeTargetsWithUpdatedRoutingAuthority.${targetName};
            targetPath = "${sitePath}.runtimeTargets.${targetName}";
            logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
            nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
          in
          {
            name = nodeName;
            value = (target.routingAuthority.defaultReachability or false);
          })
        runtimeTargetNames
    );

  forwardingSemanticsNodeNames =
    sortedNames (
      makeStringSet (
        (sortedNames runtimeTargetsByNode)
        ++ (sortedNames forwardingSemanticsNodes)
      )
    );

  updatedForwardingSemanticsNodes =
    builtins.listToAttrs (
      builtins.map
        (nodeName:
          let
            existingNodeSemantics =
              if hasAttr nodeName forwardingSemanticsNodes then
                attrsOrEmpty forwardingSemanticsNodes.${nodeName}
              else
                { };
            existingRoutingAuthority =
              attrsOrEmpty (existingNodeSemantics.routingAuthority or null);
            defaultReachability =
              if hasAttr nodeName defaultReachabilityByNode then
                defaultReachabilityByNode.${nodeName}
              else if builtins.hasAttr "defaultReachability" existingRoutingAuthority then
                existingRoutingAuthority.defaultReachability
              else
                false;
          in
          {
            name = nodeName;
            value =
              existingNodeSemantics
              // {
                routingAuthority =
                  existingRoutingAuthority
                  // {
                    inherit defaultReachability;
                  };
              };
          })
        forwardingSemanticsNodeNames
    );

  updatedForwardingSemantics =
    forwardingSemantics
    // {
      nodes = updatedForwardingSemanticsNodes;
    };
in
{
  runtimeTargets = runtimeTargetsWithUpdatedRoutingAuthority;
  forwardingSemantics = updatedForwardingSemantics;
}
