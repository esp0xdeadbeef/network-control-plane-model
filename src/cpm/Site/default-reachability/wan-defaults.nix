{
  helpers,
  common,
  sitePath,
  siteOverlayNameSet,
  exitNodeSet,
  runtimeTargets,
  runtimeTargetNames,
  uplinkRouting,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs requireString sortedNames;
  inherit (common)
    attrsOrEmpty
    buildWANDefaultRoute
    listContains
    listOrEmpty
    makeStringSet
    routesContainDefault
    stripDefaultRoutes
    ;

  staticRouteForFamily = family: route:
    let
      dst = route.prefix or route.dst or null;
      via = route.via or null;
      default = if family == 4 then "0.0.0.0/0" else "::/0";
    in
    if !isNonEmptyString dst || !isNonEmptyString via then
      null
    else
      {
        inherit dst;
        intent = {
          kind = if dst == default then "default-reachability" else "uplink-learned-reachability";
          source = "explicit-uplink-static";
        };
        proto = "upstream";
      }
      // {
        ${if family == 4 then "via4" else "via6"} = via;
      };

  staticUplinkRoutes =
    family: uplinkName:
    let
      uplinkCfg = if isNonEmptyString uplinkName && hasAttr uplinkName uplinkRouting then uplinkRouting.${uplinkName} else null;
      staticCfg = attrsOrEmpty (uplinkCfg.static or null);
      routes = attrsOrEmpty (staticCfg.routes or null);
      familyRoutes = if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);
    in
    if uplinkCfg == null || (uplinkCfg.mode or null) != "static" then
      [ ]
    else
      builtins.filter (route: route != null) (builtins.map (staticRouteForFamily family) familyRoutes);

  selectedUplinkNamesForTarget = target:
    let
      egressIntent = attrsOrEmpty (target.egressIntent or null);
    in
    (if builtins.isList (egressIntent.uplinks or null) then
      builtins.filter isNonEmptyString egressIntent.uplinks
    else
      [ ])
    ++ (
      if builtins.isList (egressIntent.wanInterfaces or null) then
        builtins.filter isNonEmptyString egressIntent.wanInterfaces
      else
        [ ]
    );

  augmentWANInterfaceRoutes = selectedUplinkSet: selectedUplinkNames: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      hostUplink = attrsOrEmpty (iface.hostUplink or null);
      wan = attrsOrEmpty (iface.wan or null);
      upstream = iface.upstream or null;
      isOverlayTransportUplink = isNonEmptyString upstream && hasAttr upstream siteOverlayNameSet;
      selected =
        selectedUplinkNames == [ ]
        || (isNonEmptyString upstream && hasAttr upstream selectedUplinkSet);
      ipv4Routes = listOrEmpty (routes.ipv4 or null);
      ipv6Routes = listOrEmpty (routes.ipv6 or null);
      staticIPv4Routes = staticUplinkRoutes 4 upstream;
      staticIPv6Routes = staticUplinkRoutes 6 upstream;
      wantsIPv4Default =
        !isOverlayTransportUplink
        && selected
        && (builtins.isAttrs (hostUplink.ipv4 or null) || listContains "0.0.0.0/0" (wan.ipv4 or null));
      wantsIPv6Default =
        !isOverlayTransportUplink
        && selected
        && (builtins.isAttrs (hostUplink.ipv6 or null) || listContains "::/0" (wan.ipv6 or null));
      updatedIPv4Routes =
        if isOverlayTransportUplink then
          stripDefaultRoutes 4 ipv4Routes
        else if staticIPv4Routes != [ ] then
          stripDefaultRoutes 4 ipv4Routes ++ staticIPv4Routes
        else if wantsIPv4Default && !routesContainDefault 4 ipv4Routes then
          ipv4Routes ++ [ (buildWANDefaultRoute 4) ]
        else
          ipv4Routes;
      updatedIPv6Routes =
        if isOverlayTransportUplink then
          stripDefaultRoutes 6 ipv6Routes
        else if staticIPv6Routes != [ ] then
          stripDefaultRoutes 6 ipv6Routes ++ staticIPv6Routes
        else if wantsIPv6Default && !routesContainDefault 6 ipv6Routes then
          ipv6Routes ++ [ (buildWANDefaultRoute 6) ]
        else
          ipv6Routes;
    in
    iface
    // {
      routes = routes // {
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
        effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
        interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
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
                      augmentWANInterfaceRoutes selectedUplinkSet selectedUplinkNames iface
                    else
                      iface;
                })
              (sortedNames interfaces)
          );
      in
      target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; };

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
            value = { inherit targetName target; };
          })
        runtimeTargetNames
    );

in
{
  inherit
    runtimeTargetsWithWANDefaults
    runtimeTargetsWithWANDefaultsByNode
    selectedUplinkNamesForTarget
    ;
}
