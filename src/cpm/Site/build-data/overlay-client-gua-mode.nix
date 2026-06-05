{ helpers
, common
,
}:

{ runtimeTargets ? { }
,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

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

  routesForInterface =
    iface:
    builtins.map
      (route:
        (attrsOrEmpty route)
        // {
          _targetName = iface._targetName;
          _interfaceName = iface._interfaceName;
          _logicalNode = iface.logicalNode or null;
          _sourceKind = iface.sourceKind or null;
          _overlay =
            if isNonEmptyString (route.overlay or null) then
              route.overlay
            else
              ((attrsOrEmpty (iface.backingRef or null)).name or null);
          _tenant = iface.tenant or null;
        })
      (listOrEmpty ((attrsOrEmpty (iface.routes or null)).ipv6 or null));

  ipv6Routes =
    builtins.concatLists (builtins.map routesForInterface runtimeInterfaces);

  delegatedOverlayDefaults =
    builtins.filter
      (route:
        (route.dst or null) == "::/0"
        && (route.policyOnly or false) == true
        && routeIntentKind route == "delegated-public-egress"
        && ((route.proto or null) == "overlay" || isNonEmptyString (route._overlay or null)))
      ipv6Routes;

  keyForRecord = record:
    "${record.sourceFile or ""}|${record.tenant or ""}|${record.exitNode or ""}|${record.overlay or ""}|${record.egressRuntimeTarget or ""}|${record.egressInterface or ""}";

  returnMatches = candidate: route:
    routeIntentKind route == "runtime-routed-prefix-return"
    && (
      (isNonEmptyString (candidate.sourceFile or null) && (route.sourceFile or null) == candidate.sourceFile)
      || (
        !isNonEmptyString (candidate.sourceFile or null)
        && isNonEmptyString (candidate.tenant or null)
        && ((route.tenant or null) == candidate.tenant || (route._tenant or null) == candidate.tenant)
      )
      || (
        !isNonEmptyString (candidate.sourceFile or null)
        && isNonEmptyString ((attrsOrEmpty (candidate.intent or null)).exitNode or null)
        && ((attrsOrEmpty (route.intent or null)).accessNode or null) == candidate.intent.exitNode
      )
    );

  returnRoutesFor = candidate:
    builtins.filter (route: returnMatches candidate route) ipv6Routes;

  routeRecord = route:
    {
      runtimeTarget = route._targetName;
      interface = route._interfaceName;
      proto = route.proto or null;
    }
    // (if isNonEmptyString (route._overlay or null) then { overlay = route._overlay; } else { })
    // (if isNonEmptyString (route.sourceFile or null) then { sourceFile = route.sourceFile; } else { })
    // (if isNonEmptyString (route.tenant or null) then { tenant = route.tenant; } else { })
    // (if isNonEmptyString (route.via6 or null) then { via6 = route.via6; } else { });

  candidateIsComplete = candidate:
    isNonEmptyString (candidate._overlay or null)
    && (
      isNonEmptyString (candidate.sourceFile or null)
      || isNonEmptyString (candidate.tenant or null)
      || isNonEmptyString ((attrsOrEmpty (candidate.intent or null)).exitNode or null)
    )
    && candidate._returnRoutes != [ ];

  candidatesWithReturnRoutes =
    builtins.map
      (candidate:
        candidate
        // {
          _returnRoutes = returnRoutesFor candidate;
        })
      delegatedOverlayDefaults;

  records =
    builtins.map
      (candidate:
        let
          returnRoutes = candidate._returnRoutes;
          sourceFiles = uniqueStrings (
            builtins.map
              (route: route.sourceFile)
              (builtins.filter (route: isNonEmptyString (route.sourceFile or null)) returnRoutes)
          );
          tenants = uniqueStrings (
            builtins.map
              (route: route.tenant)
              (builtins.filter (route: isNonEmptyString (route.tenant or null)) returnRoutes)
          );
          sourceFile =
            if isNonEmptyString (candidate.sourceFile or null) then
              candidate.sourceFile
            else if sourceFiles != [ ] then
              builtins.head sourceFiles
            else
              null;
          tenant =
            if isNonEmptyString (candidate.tenant or null) then
              candidate.tenant
            else if tenants != [ ] then
              builtins.head tenants
            else
              null;
        in
        {
          mode = "overlay-client-gua";
          overlay = candidate._overlay;
          egressRuntimeTarget = candidate._targetName;
          egressInterface = candidate._interfaceName;
          source = "intent-routed-prefix";
          defaultRoute = routeRecord candidate;
          returnRoutes = builtins.map routeRecord returnRoutes;
        }
        // (if isNonEmptyString sourceFile then { sourceFile = sourceFile; } else { })
        // (if isNonEmptyString tenant then { tenant = tenant; } else { })
        // (if isNonEmptyString ((attrsOrEmpty (candidate.intent or null)).exitNode or null) then { exitNode = candidate.intent.exitNode; } else { })
        // (if isNonEmptyString (candidate.peerSite or null) then { peerSite = candidate.peerSite; } else { }))
      (builtins.filter candidateIsComplete candidatesWithReturnRoutes);

  diagnosticFor = candidate:
    let
      missing = builtins.filter (value: value != null) [
        (if isNonEmptyString (candidate._overlay or null) then null else "overlay-path")
        (
          if
            isNonEmptyString (candidate.sourceFile or null)
            || isNonEmptyString (candidate.tenant or null)
            || isNonEmptyString ((attrsOrEmpty (candidate.intent or null)).exitNode or null)
          then
            null
          else
            "source-scope"
        )
        (if candidate._returnRoutes != [ ] then null else "return-behavior")
      ];
    in
    if missing == [ ] then
      [ ]
    else
      [
        (
          {
            code = "overlay-client-gua-authority-unavailable";
            mode = "fail-closed";
            missing = missing;
            message = "Policy-routed overlay client GUA mode requires overlay path, source scope, and return behavior before renderer output.";
          }
          // (if isNonEmptyString (candidate._overlay or null) then { overlay = candidate._overlay; } else { })
          // (if isNonEmptyString (candidate.sourceFile or null) then { sourceFile = candidate.sourceFile; } else { })
          // (if isNonEmptyString (candidate.tenant or null) then { tenant = candidate.tenant; } else { })
          // (if isNonEmptyString ((attrsOrEmpty (candidate.intent or null)).exitNode or null) then { exitNode = candidate.intent.exitNode; } else { })
        )
      ];

  diagnostics =
    builtins.concatLists (builtins.map diagnosticFor candidatesWithReturnRoutes);

  keyedRecords = builtins.listToAttrs (
    builtins.map (record: { name = keyForRecord record; value = record; }) records
  );
in
{
  records = builtins.map (key: keyedRecords.${key}) (sortedNames keyedRecords);
  diagnostics = diagnostics;
}
