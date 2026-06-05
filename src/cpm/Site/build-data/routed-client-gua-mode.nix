{ helpers
, common
,
}:

{ tenantPrefixOwners ? { }
, runtimeTargets ? { }
,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  isRoutedClientGuaPrefix = value:
    isNonEmptyString value && builtins.match "^[23][0-9A-Fa-f]{3}:.*" value != null;

  routeIntentKind = route:
    ((attrsOrEmpty (route.intent or null)).kind or null);

  interfacesForTarget =
    targetName:
    let
      target = attrsOrEmpty (runtimeTargets.${targetName} or null);
      realization = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (realization.interfaces or null);
    in
    builtins.map
      (interfaceName:
        (attrsOrEmpty (interfaces.${interfaceName} or null))
        // {
          _targetName = targetName;
          _interfaceName = interfaceName;
        })
      (sortedNames interfaces);

  runtimeInterfaces =
    builtins.concatLists (
      builtins.map interfacesForTarget (sortedNames runtimeTargets)
    );

  routeEntriesForInterface =
    iface:
    builtins.map
      (route:
        (attrsOrEmpty route)
        // {
          _targetName = iface._targetName;
          _interfaceName = iface._interfaceName;
          _logicalNode = iface.logicalNode or null;
          _tenant = iface.tenant or null;
        })
      (listOrEmpty ((attrsOrEmpty (iface.routes or null)).ipv6 or null));

  ipv6Routes =
    builtins.concatLists (builtins.map routeEntriesForInterface runtimeInterfaces);

  connectedGuaRoutes =
    builtins.filter
      (route:
        isRoutedClientGuaPrefix (route.dst or null)
        && routeIntentKind route == "connected-reachability"
        && isNonEmptyString (route._tenant or null))
      ipv6Routes;

  ownerEntries =
    builtins.filter
      (owner:
        (owner.family or null) == 6
        && isRoutedClientGuaPrefix (owner.dst or null)
        && isNonEmptyString (owner.owner or null))
      (builtins.attrValues tenantPrefixOwners);

  reverseList =
    values:
    builtins.foldl' (acc: value: [ value ] ++ acc) [ ] values;

  groupByDst =
    routes:
    builtins.foldl'
      (
        acc: route:
        let
          dst = route.dst or null;
        in
        if isNonEmptyString dst then
          acc // {
            ${dst} = [ route ] ++ (acc.${dst} or [ ]);
          }
        else
          acc
      )
      { }
      routes;

  ownerByDst =
    builtins.foldl'
      (
        acc: owner:
        let
          dst = owner.dst or null;
        in
        if isNonEmptyString dst && !(builtins.hasAttr dst acc) then
          acc // { ${dst} = owner; }
        else
          acc
      )
      { }
      ownerEntries;

  connectedByDst = groupByDst connectedGuaRoutes;

  returnByDst =
    groupByDst (
      builtins.filter
        (route: routeIntentKind route == "internal-reachability")
        ipv6Routes
    );

  allPrefixes = uniqueStrings (
    (builtins.map (owner: owner.dst) ownerEntries)
    ++ (builtins.map (route: route.dst) connectedGuaRoutes)
  );

  connectedForPrefix = prefix:
    reverseList (connectedByDst.${prefix} or [ ]);

  returnRoutesForPrefix = prefix:
    reverseList (returnByDst.${prefix} or [ ]);

  ownerForPrefix = prefix:
    ownerByDst.${prefix} or null;

  returnRouteRecord = route:
    {
      runtimeTarget = route._targetName;
      interface = route._interfaceName;
      proto = route.proto or null;
    }
    // (if isNonEmptyString (route.via6 or null) then { via6 = route.via6; } else { });

  recordsForPrefix =
    prefix:
    let
      owner = ownerForPrefix prefix;
      returnRoutes = returnRoutesForPrefix prefix;
    in
    if owner != null && returnRoutes != [ ] then
      [
        {
          mode = "routed-client-gua";
          prefix = prefix;
          tenant = owner.netName or null;
          owner = owner.owner;
          source = "tenant-prefix-owner";
          returnRoute = returnRouteRecord (builtins.head returnRoutes);
          returnRoutes = builtins.map returnRouteRecord returnRoutes;
        }
      ]
    else
      [ ];

  diagnosticsForPrefix =
    prefix:
    let
      owner = ownerForPrefix prefix;
      connectedRoutes = connectedForPrefix prefix;
      returnRoutes = returnRoutesForPrefix prefix;
      accessNodes = uniqueStrings (
        builtins.map
          (route: route._logicalNode)
          (builtins.filter (route: isNonEmptyString (route._logicalNode or null)) connectedRoutes)
      );
    in
    (
      if owner == null && connectedRoutes != [ ] then
        [
          {
            code = "routed-gua-authority-unavailable";
            mode = "fail-closed";
            prefix = prefix;
            inherit accessNodes;
            message = "Routed client GUA mode observed a connected GUA prefix without explicit tenant prefix authority.";
          }
        ]
      else
        [ ]
    )
    ++ (
      if owner != null && returnRoutes == [ ] then
        [
          {
            code = "routed-gua-return-route-unavailable";
            mode = "fail-closed";
            prefix = prefix;
            tenant = owner.netName or null;
            owner = owner.owner;
            message = "Routed client GUA mode requires an internal IPv6 return route for the client GUA prefix.";
          }
        ]
      else
        [ ]
    );
in
{
  records = builtins.concatLists (builtins.map recordsForPrefix allPrefixes);
  diagnostics = builtins.concatLists (builtins.map diagnosticsForPrefix allPrefixes);
}
