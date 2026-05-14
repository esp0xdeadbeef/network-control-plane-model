{
  lib,
  helpers,
  common,
  sitePath,
  siteAttrs,
  allSiteEntries,
  allRuntimeRoutedIPv6Prefixes,
  siteOverlayNameSet,
  sortedCandidatePaths,
  preferredFirstHopMatchesSource,
  routeHelpers,
  runtimeRoutedIPv6PrefixesByAccessNode,
}:

let
  inherit (helpers) hasAttr requireAttrs requireString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty makeStringSet;
  inherit (routeHelpers)
    findInterfaceNameForAdjacency
    ;
  p2pPeers = import ../../ControlModule/route-augmentation/p2p-peers.nix { inherit lib; };

  siteId = siteAttrs.siteId or null;

  remoteRuntimeRoutedPrefixes =
    builtins.filter
      (prefix:
        builtins.isAttrs prefix
        && (prefix.siteId or null) != siteId
        && (prefix.family or null) == "ipv6"
        && (prefix.allocation or null) == "runtime"
        && prefixHasSourceFile prefix)
      allRuntimeRoutedIPv6Prefixes;

  prefixHasSourceFile =
    prefix: builtins.isAttrs prefix && builtins.isString (prefix.sourceFile or null) && prefix.sourceFile != "";

  routeExists =
    routes: sourceFile: via6:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.sourceFile or null) == sourceFile
        && (route.via6 or null) == via6
        && ((attrsOrEmpty (route.intent or null)).kind or null) == "runtime-routed-prefix-return")
      (listOrEmpty routes);

  buildRoute =
    accessNodeName: prefix: via6:
    {
      family = 6;
      metric = 50;
      sourceFile = prefix.sourceFile;
      delegatedPrefix = prefix;
      via6 = via6;
      proto = "internal";
      intent = {
        kind = "runtime-routed-prefix-return";
        source = "inventory-routed-prefix";
        accessNode = accessNodeName;
      };
    };

  addPrefixRoutesForAccess =
    targetName: nodeName: targetPath: accessNodeName: prefixes: interfaces:
    if nodeName == accessNodeName || prefixes == [ ] then
      interfaces
    else
      let
        candidates =
          builtins.filter
            (candidate: candidate.steps != [ ])
            (sortedCandidatePaths 6 (makeStringSet [ accessNodeName ]) nodeName);
        candidateEntries =
          builtins.map
            (candidate:
              let firstStep = builtins.elemAt candidate.steps 0;
              in {
                inherit candidate firstStep;
                interfaceName = findInterfaceNameForAdjacency targetName { effectiveRuntimeRealization.interfaces = interfaces; } firstStep.adjacencyId;
              })
            candidates;
        namedCandidates = builtins.filter (entry: entry.interfaceName != null) candidateEntries;
        accessScoped =
          builtins.filter (
            entry:
            let
              iface = attrsOrEmpty (interfaces.${entry.interfaceName} or null);
              backingRef = attrsOrEmpty (iface.backingRef or null);
              lane = attrsOrEmpty (backingRef.lane or null);
            in
            (lane.access or null) == accessNodeName
          ) namedCandidates;
        scoped = if accessScoped != [ ] then accessScoped else namedCandidates;
        chosen = if scoped == [ ] then null else builtins.elemAt scoped 0;
        firstStep = if chosen == null then null else chosen.firstStep;
        interfaceName = if chosen == null then null else chosen.interfaceName;
      in
      if interfaceName == null || !hasAttr interfaceName interfaces then
        interfaces
      else
        let
          iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}" interfaces.${interfaceName};
          routes = attrsOrEmpty (iface.routes or null);
          existing = listOrEmpty (routes.ipv6 or null);
          updated =
            builtins.foldl'
              (acc: prefix:
                if !prefixHasSourceFile prefix || routeExists acc prefix.sourceFile firstStep.via then
                  acc
                else
                  acc ++ [ (buildRoute accessNodeName prefix firstStep.via) ])
              existing
              prefixes;
          updatedIface = iface // { routes = routes // { ipv6 = updated; }; };
        in
        interfaces // { ${interfaceName} = updatedIface; };

  routeForRemotePrefix =
    iface: prefix:
    let peer = p2pPeers.peerForInterface 6 iface;
    in
    if peer == null then
      null
    else
      buildRoute (prefix.accessNode or "remote-runtime-routed-prefix") prefix peer;

  addRemotePrefixRoutesToInterface =
    iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      existing = listOrEmpty (routes.ipv6 or null);
      updated =
        builtins.foldl'
          (acc: prefix:
            let route = routeForRemotePrefix iface prefix;
            in
            if route == null || routeExists acc prefix.sourceFile route.via6 then
              acc
            else
              acc ++ [ route ])
          existing
          remoteRuntimeRoutedPrefixes;
    in
    iface // { routes = routes // { ipv6 = updated; }; };

  isRemoteReturnInterface =
    targetRole: iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (backingRef.lane or null);
      laneUplinks =
        if builtins.isList (lane.uplinks or null) then
          lane.uplinks
        else if lane.uplink or null == null then
          [ ]
        else
          [ lane.uplink ];
      laneUsesOverlay = builtins.any (uplinkName: hasAttr uplinkName siteOverlayNameSet) laneUplinks;
      isTransit = (backingRef.kind or null) == "link" && (iface.addr6 or null) != null;
    in
    remoteRuntimeRoutedPrefixes != [ ]
    && isTransit
    && (
      targetRole == "core"
      || (targetRole == "upstream-selector" && laneUsesOverlay)
    );

  addRemotePrefixRoutes =
    target:
    let
      targetRole = target.role or null;
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      updatedInterfaces =
        builtins.mapAttrs
          (_: iface:
            if isRemoteReturnInterface targetRole iface then
              addRemotePrefixRoutesToInterface iface
            else
              iface)
          interfaces;
    in
    target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; };

in
{
  add = targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
      nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
      interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
      updatedInterfaces =
        builtins.foldl'
          (current: accessNodeName:
            addPrefixRoutesForAccess targetName nodeName targetPath accessNodeName runtimeRoutedIPv6PrefixesByAccessNode.${accessNodeName} current)
          interfaces
          (sortedNames runtimeRoutedIPv6PrefixesByAccessNode);
    in
    addRemotePrefixRoutes (target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; });
}
