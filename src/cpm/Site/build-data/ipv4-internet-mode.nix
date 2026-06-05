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

  routeIntentKind = route:
    ((attrsOrEmpty (route.intent or null)).kind or null);

  isPrivate4Prefix = value:
    isNonEmptyString value
    && builtins.match "^(10\\..*|172\\.(1[6-9]|2[0-9]|3[0-1])\\..*|192\\.168\\..*)$" value != null;

  isIpv4Prefix = value:
    isNonEmptyString value && builtins.match "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$" value != null;

  isHostOnlyIpv4Prefix = value:
    isNonEmptyString value && builtins.match "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/32$" value != null;

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
          _target = target;
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
      (listOrEmpty ((attrsOrEmpty (iface.routes or null)).ipv4 or null));

  ipv4Routes =
    builtins.concatLists (builtins.map routeEntriesForInterface runtimeInterfaces);

  ownerEntries =
    builtins.filter
      (owner:
        (owner.family or null) == 4
        && isIpv4Prefix (owner.dst or null)
        && isNonEmptyString (owner.owner or null))
      (builtins.attrValues tenantPrefixOwners);

  ownerForPrefix = prefix:
    let
      matches = builtins.filter (owner: (owner.dst or null) == prefix) ownerEntries;
    in
    if matches == [ ] then null else builtins.head matches;

  connectedForPrefix = prefix:
    builtins.filter
      (route:
        (route.dst or null) == prefix
        && routeIntentKind route == "connected-reachability")
      ipv4Routes;

  returnRoutesForPrefix = prefix:
    builtins.filter
      (route:
        (route.dst or null) == prefix
        && routeIntentKind route == "internal-reachability")
      ipv4Routes;

  routeRecord = route:
    {
      runtimeTarget = route._targetName;
      interface = route._interfaceName;
      proto = route.proto or null;
    }
    // (if isNonEmptyString (route.via4 or null) then { via4 = route.via4; } else { });

  natTargets =
    builtins.filter
      (targetName:
        let
          natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
        in
        (natIntent.families.ipv4 or false) == true)
      (sortedNames runtimeTargets);

  privateNatRecords =
    builtins.concatMap
      (targetName:
        let
          target = attrsOrEmpty (runtimeTargets.${targetName} or null);
          natIntent = attrsOrEmpty (target.natIntent or null);
          routeSafety = attrsOrEmpty ((attrsOrEmpty (natIntent.routeSafety or null)).coreOriginUplinkDefault or null);
          exceptions = attrsOrEmpty (routeSafety.sourceScopedTranslationExceptions or null);
          sourcePrefixes = listOrEmpty (natIntent.masqueradeSourcePrefixes4 or null);
          privateSources = builtins.filter isPrivate4Prefix sourcePrefixes;
        in
        if privateSources == [ ] then
          [ ]
        else
          [
            {
              mode = "private-nat44";
              runtimeTarget = targetName;
              source = "runtimeTargets.*.natIntent";
              sourcePrefixes = privateSources;
              uplinks = natIntent.uplinks or [ ];
              outputInterfaces = natIntent.masqueradeInterfaces4 or [ ];
              routeSafety = {
                blackholed = routeSafety.blackholed or false;
                sourceScopedTranslation = exceptions.nat44 or false;
                boundaries = exceptions.nat44Boundaries or [ ];
                sourcePrefixes = exceptions.nat44SourcePrefixes or [ ];
                outputInterfaces = exceptions.nat44OutputInterfaces or [ ];
              };
            }
          ])
      natTargets;

  publicOwnerEntries =
    builtins.filter (owner: !(isPrivate4Prefix (owner.dst or null)) && !isHostOnlyIpv4Prefix (owner.dst or null)) ownerEntries;

  routedPublicRecords =
    builtins.concatMap
      (owner:
        let
          prefix = owner.dst;
          returnRoutes = returnRoutesForPrefix prefix;
        in
        if returnRoutes == [ ] then
          [ ]
        else
          [
            {
              mode = "routed-public-ipv4";
              prefix = prefix;
              tenant = owner.netName or null;
              owner = owner.owner;
              source = "tenant-prefix-owner";
              returnRoute = routeRecord (builtins.head returnRoutes);
              returnRoutes = builtins.map routeRecord returnRoutes;
              nat44 = false;
            }
          ])
      publicOwnerEntries;

  wanHostOnlyAddresses =
    uniqueStrings (
      builtins.filter isHostOnlyIpv4Prefix (
        builtins.map
          (iface:
            let
              explicitAddress = (attrsOrEmpty (iface.ipv4 or null)).address or null;
              hostUplinkAddress = (attrsOrEmpty ((attrsOrEmpty (iface.hostUplink or null)).ipv4 or null)).address or null;
            in
            if iface.addr4 or null != null then
              iface.addr4
            else if explicitAddress != null then
              explicitAddress
            else
              hostUplinkAddress)
          (builtins.filter (iface: (iface.sourceKind or null) == "wan") runtimeInterfaces)
      )
    );

  tenantClaimsPrefix = prefix:
    builtins.any
      (route:
        (route.dst or null) == prefix
        && routeIntentKind route == "connected-reachability"
        && isNonEmptyString (route._tenant or null))
      ipv4Routes;

  natClaimsPrefix = prefix:
    builtins.any
      (targetName:
        let
          natIntent = attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null);
        in
        builtins.elem prefix (natIntent.masqueradeSourcePrefixes4 or [ ]))
      (sortedNames runtimeTargets);

  hostOnlyBoundaryRecords =
    builtins.map
      (prefix: {
        mode = "host-only-ipv4-boundary";
        prefix = prefix;
        source = "wan-realization";
        downstreamExport = false;
        tenantAuthority = false;
        nat44SourceAuthority = false;
      })
      (
        builtins.filter
          (prefix: !(tenantClaimsPrefix prefix) && returnRoutesForPrefix prefix == [ ] && !(natClaimsPrefix prefix))
          wanHostOnlyAddresses
      );

  routedPublicDiagnostics =
    builtins.concatMap
      (owner:
        let
          prefix = owner.dst;
          connectedRoutes = connectedForPrefix prefix;
          returnRoutes = returnRoutesForPrefix prefix;
        in
        if connectedRoutes != [ ] && returnRoutes == [ ] then
          [
            {
              code = "routed-public-ipv4-return-route-unavailable";
              mode = "fail-closed";
              prefix = prefix;
              tenant = owner.netName or null;
              owner = owner.owner;
              message = "Routed public IPv4 mode requires an internal return route for the public client prefix.";
            }
          ]
        else
          [ ])
      publicOwnerEntries;

  hostOnlyDiagnostics =
    builtins.map
      (prefix: {
        code = "host-only-ipv4-downstream-export-denied";
        mode = "fail-closed";
        prefix = prefix;
        downstreamExport = false;
        message = "Host-only IPv4 upstream address is WAN realization authority only and is denied as tenant, return-route, or NAT44 source authority.";
      })
      (
        builtins.filter
          (prefix: !(tenantClaimsPrefix prefix) && returnRoutesForPrefix prefix == [ ] && !(natClaimsPrefix prefix))
          wanHostOnlyAddresses
      );
in
{
  records = {
    privateNat44 = privateNatRecords;
    routedPublicIpv4 = routedPublicRecords;
    hostOnlyIpv4Boundary = hostOnlyBoundaryRecords;
  };
  diagnostics = {
    routedPublicIpv4 = routedPublicDiagnostics;
    hostOnlyIpv4Boundary = hostOnlyDiagnostics;
  };
}
