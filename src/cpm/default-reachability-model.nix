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
    if builtins.isAttrs (siteAttrs.forwardingSemantics or null) then
      siteAttrs.forwardingSemantics
    else
      null;

  forwardingSemanticsNodes =
    if forwardingSemantics == null then
      { }
    else
      attrsOrEmpty (forwardingSemantics.nodes or null);

  siteEgressIntent =
    attrsOrEmpty (siteAttrs.egressIntent or null);

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

  augmentWANInterfaceRoutes = iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      wan = attrsOrEmpty (iface.wan or null);

      ipv4Routes = listOrEmpty (routes.ipv4 or null);
      ipv6Routes = listOrEmpty (routes.ipv6 or null);

      wantsIPv4Default = listContains "0.0.0.0/0" (wan.ipv4 or null);
      wantsIPv6Default = listContains "::/0" (wan.ipv6 or null);

      updatedIPv4Routes =
        if wantsIPv4Default && !routesContainDefault 4 ipv4Routes then
          ipv4Routes ++ [ (buildWANDefaultRoute 4) ]
        else
          ipv4Routes;

      updatedIPv6Routes =
        if wantsIPv6Default && !routesContainDefault 6 ipv6Routes then
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
                iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
              in
              {
                name = ifName;
                value =
                  if (iface.sourceKind or null) == "wan" then
                    augmentWANInterfaceRoutes iface
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
    in
    if sortedNames exitNodeSet == [ ] then
      nodesWithExplicitDefaults
    else
      builtins.filter
        (nodeName: hasAttr nodeName exitNodeSet)
        nodesWithExplicitDefaults;

  explicitDefaultSourceSet4 =
    makeStringSet (explicitDefaultSourceNodeNamesForFamily 4);

  explicitDefaultSourceSet6 =
    makeStringSet (explicitDefaultSourceNodeNamesForFamily 6);

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

  pickBetterPath = current: candidate:
    if current == null then
      candidate
    else if builtins.length candidate.steps < builtins.length current.steps then
      candidate
    else
      current;

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

  findBestPath = family: sourceSet: nodeName:
    builtins.foldl'
      pickBetterPath
      null
      (findCandidatePaths family sourceSet nodeName { });

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
            (backingRef.kind or null) == "link"
            && (backingRef.id or null) == adjacencyId)
          (sortedNames interfaces);
    in
    if matchingNames == [ ] then
      null
    else
      builtins.elemAt matchingNames 0;

  buildInternalDefaultRoute = family: sourceNode: via:
    {
      dst = defaultDst family;
      intent = {
        kind = "default-reachability";
        source = "explicit-exit";
        exitNode = sourceNode;
      };
      proto = "internal";
    }
    // {
      ${if family == 4 then "via4" else "via6"} = via;
    };

  synthesizeDefaultForFamily = family: sourceSet: targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
    in
    if targetHasDefaultReachabilityForFamily family targetName target then
      target
    else
      let
        bestPath = findBestPath family sourceSet nodeName;
      in
      if bestPath == null || bestPath.steps == [ ] then
        target
      else
        let
          firstStep = builtins.elemAt bestPath.steps 0;
          interfaceName = findInterfaceNameForAdjacency targetName target firstStep.adjacencyId;
        in
        if interfaceName == null then
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
            iface =
              requireAttrs
                "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
                interfaces.${interfaceName};
            routes = attrsOrEmpty (iface.routes or null);

            existingFamilyRoutes =
              if family == 4 then
                listOrEmpty (routes.ipv4 or null)
              else
                listOrEmpty (routes.ipv6 or null);

            updatedFamilyRoutes =
              if routesContainDefault family existingFamilyRoutes then
                existingFamilyRoutes
              else
                existingFamilyRoutes
                ++ [
                  (buildInternalDefaultRoute family bestPath.sourceNode firstStep.via)
                ];

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

            updatedInterfaces =
              interfaces
              // {
                ${interfaceName} = updatedIface;
              };
          in
          target
          // {
            effectiveRuntimeRealization =
              effective
              // {
                interfaces = updatedInterfaces;
              };
          };

  runtimeTargetsWithSynthesizedDefaults =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target0 = runtimeTargetsWithWANDefaults.${targetName};
            target1 = synthesizeDefaultForFamily 4 explicitDefaultSourceSet4 targetName target0;
            target2 = synthesizeDefaultForFamily 6 explicitDefaultSourceSet6 targetName target1;
          in
          {
            name = targetName;
            value = target2;
          })
        runtimeTargetNames
    );

  targetHasAnyDefaultReachability = targetName: target:
    targetHasDefaultReachabilityForFamily 4 targetName target
    || targetHasDefaultReachabilityForFamily 6 targetName target;

  runtimeTargetsWithUpdatedRoutingAuthority =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target = runtimeTargetsWithSynthesizedDefaults.${targetName};
            routingAuthority = target.routingAuthority or null;
            hasDerivedDefault = targetHasAnyDefaultReachability targetName target;
          in
          {
            name = targetName;
            value =
              if builtins.isAttrs routingAuthority then
                target
                // {
                  routingAuthority =
                    routingAuthority
                    // {
                      defaultReachability =
                        (routingAuthority.defaultReachability or false)
                        || hasDerivedDefault;
                    };
                }
              else
                target;
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
            value = targetHasAnyDefaultReachability targetName target;
          })
        runtimeTargetNames
    );

  updatedForwardingSemantics =
    if forwardingSemantics == null then
      null
    else
      let
        updatedNodes =
          builtins.listToAttrs (
            builtins.map
              (nodeName:
                let
                  nodeSemantics = forwardingSemanticsNodes.${nodeName};
                  routingAuthority = nodeSemantics.routingAuthority or null;
                  hasDerivedDefault =
                    if hasAttr nodeName defaultReachabilityByNode then
                      defaultReachabilityByNode.${nodeName}
                    else
                      false;
                in
                {
                  name = nodeName;
                  value =
                    if builtins.isAttrs routingAuthority then
                      nodeSemantics
                      // {
                        routingAuthority =
                          routingAuthority
                          // {
                            defaultReachability =
                              (routingAuthority.defaultReachability or false)
                              || hasDerivedDefault;
                          };
                      }
                    else
                      nodeSemantics;
                })
              (sortedNames forwardingSemanticsNodes)
          );
      in
      forwardingSemantics
      // {
        nodes = updatedNodes;
      };
in
{
  runtimeTargets = runtimeTargetsWithUpdatedRoutingAuthority;
  forwardingSemantics = updatedForwardingSemantics;
}
