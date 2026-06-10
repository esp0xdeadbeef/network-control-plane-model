{}:

let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };

  backingRef = iface: attrsOrEmpty (iface.backingRef or { });

  lane = iface: attrsOrEmpty ((backingRef iface).lane or { });
in
rec {
  laneKind = iface: (lane iface).kind or null;

  laneAccess = iface: (lane iface).access or null;

  laneUplink = iface: (lane iface).uplink or null;

  prefixOrigin = prefix: attrsOrEmpty (prefix.origin or null);

  prefixOriginAccesses = prefix:
    if builtins.isList ((prefixOrigin prefix).accesses or null) then (prefixOrigin prefix).accesses else [ ];

  prefixOriginUplinks = prefix:
    if builtins.isList ((prefixOrigin prefix).uplinks or null) then (prefixOrigin prefix).uplinks else [ ];

  prefixMatchesInterfaceLane =
    prefix: iface:
    let
      accesses = prefixOriginAccesses prefix;
      ifaceAccess = laneAccess iface;
      accessOk = accesses != [ ] && ifaceAccess != null && builtins.elem ifaceAccess accesses;
    in
    accessOk;

  sourcePrefixesForInterface =
    runtimeOriginSourcePrefixes: iface:
    builtins.filter (prefix: prefixMatchesInterfaceLane prefix iface) runtimeOriginSourcePrefixes;

  uniqueSourcePrefixes =
    prefixes:
    builtins.attrValues (
      builtins.listToAttrs (
        map
          (prefix: {
            name = "${builtins.toString (prefix.family or "")}|${prefix.prefix or ""}";
            value = prefix;
          })
          prefixes
      )
    );

  sourcePrefixAllowedToInterface =
    prefix: iface:
    let
      accesses = prefixOriginAccesses prefix;
      uplinks = prefixOriginUplinks prefix;
      ifaceAccess = laneAccess iface;
      ifaceUplink = laneUplink iface;
      accessOk = ifaceAccess == null || builtins.elem ifaceAccess accesses;
      uplinkOk = ifaceUplink == null || !(builtins.elem ifaceUplink uplinks);
    in
    accessOk && uplinkOk;

  sourcePrefixesAllowedToInterface =
    sourcePrefixes: iface:
    builtins.filter (prefix: sourcePrefixAllowedToInterface prefix iface) sourcePrefixes;

  routeList =
    iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
    in
    (if builtins.isList (routes.ipv4 or null) then routes.ipv4 else [ ])
    ++ (if builtins.isList (routes.ipv6 or null) then routes.ipv6 else [ ]);

  routeMatchesPrefix =
    prefix: route:
    builtins.isAttrs route
    && builtins.isString (route.dst or null)
    && route.dst == (prefix.prefix or "");

  sourcePrefixesReachableVia =
    runtimeOriginSourcePrefixes: iface:
    let
      routes = routeList iface;
    in
    uniqueSourcePrefixes (
      builtins.filter
        (prefix: prefixMatchesInterfaceLane prefix iface && builtins.any (routeMatchesPrefix prefix) routes)
        runtimeOriginSourcePrefixes
    );

  sourcePrefixesWithRouteVia =
    runtimeOriginSourcePrefixes: iface:
    let
      routes = routeList iface;
    in
    uniqueSourcePrefixes (
      builtins.filter (prefix: builtins.any (routeMatchesPrefix prefix) routes) runtimeOriginSourcePrefixes
    );

  hasDefaultRoute =
    iface:
    builtins.any
      (
        route:
        builtins.isAttrs route && ((route.dst or null) == "0.0.0.0/0" || (route.dst or null) == "::/0")
      )
      (routeList iface);

  hasAnyRuntimeOriginRoute =
    runtimeOriginSourcePrefixes: iface:
    sourcePrefixesReachableVia runtimeOriginSourcePrefixes iface != [ ];

  runtimeOriginDefaultForwardRulesWith = import ./runtime-origin-default.nix {
    inherit
      laneAccess
      selectorRuntimeRuleAudit
      sourcePrefixesForInterface
      sourcePrefixesReachableVia
      sourcePrefixesWithRouteVia
      hasDefaultRoute
      hasAnyRuntimeOriginRoute
      sourcePrefixesAllowedToInterface
      uniqueSourcePrefixes
      withSourcePrefixes
      ;
  };

  runtimeOriginDefaultForwardRules =
    runtimeOriginSourcePrefixes: interfaces:
    runtimeOriginDefaultForwardRulesWith { inherit runtimeOriginSourcePrefixes interfaces; };

  withSourcePrefixes =
    rule: sourcePrefixes:
    if sourcePrefixes == [ ] then rule else rule // { inherit sourcePrefixes; };

  uplinks = iface:
    let
      ref = backingRef iface;
      laneValue = lane iface;
    in
    builtins.filter (uplink: uplink != null) (
      (ref.uplinks or [ ])
      ++ (laneValue.uplinks or [ ])
      ++ (if (laneValue.uplink or null) == null then [ ] else [ laneValue.uplink ])
    );

  selectorScope = iface:
    let
      ref = backingRef iface;
      laneValue = lane iface;
    in
    {
      runtimeInterface = iface.runtimeIfName;
      relationPurpose =
        if (laneValue.kind or null) == "access-edge" then
          "access-to-selector"
        else if (laneValue.kind or null) == "access" then
          "selector-to-policy"
        else if (laneValue.uplink or null) != null then
          "selector-policy-uplink"
        else if uplinks iface != [ ] then
          "selector-core-transport"
        else
          "selector-transport";
      lane = laneValue;
      backingRef = ref;
      hostFacing = false;
    };

  interfaceScope = iface:
    let
      ref = backingRef iface;
      laneValue = lane iface;
      fabricLink = attrsOrEmpty (iface.fabricLink or null);
      hygieneBoundaryFields =
        (if builtins.hasAttr "boundaryIdentity" iface then { boundaryIdentity = iface.boundaryIdentity; } else { })
        // (if builtins.hasAttr "sourceScopeAuthority" iface then { sourceScopeAuthority = iface.sourceScopeAuthority; } else { })
        // (if builtins.hasAttr "hygieneDecision" iface then { hygieneDecision = iface.hygieneDecision; } else { })
        // (if builtins.hasAttr "spoofing" iface then { spoofing = iface.spoofing; } else { })
        // (if builtins.hasAttr "hygieneBoundary" iface then { hygieneBoundary = iface.hygieneBoundary; } else { });
    in
    {
      runtimeInterface = iface.runtimeIfName;
      logicalInterface = iface.sourceInterface or null;
      sourceKind = iface.sourceKind or null;
      adapterClass = iface.adapterClass or null;
      virtualAdapter = iface.virtualAdapter or false;
      hostFacing = iface.hostFacing or false;
      lane = laneValue;
      backingRef = ref;
    }
    // (if (iface.tenant or null) != null then { tenant = iface.tenant; } else { })
    // (if (iface.upstream or null) != null then { upstream = iface.upstream; } else { })
    // (if (iface.overlay or null) != null then { overlay = iface.overlay; } else { })
    // (if (iface.provider or null) != null then { provider = iface.provider; } else { })
    // (if (fabricLink.link or null) != null then { fabricLink = fabricLink.link; } else { })
    // hygieneBoundaryFields;

  candidateEgress = iface:
    let
      scope = interfaceScope iface;
    in
    scope // {
      uplinks = uplinks iface;
      access = laneAccess iface;
      uplink = laneUplink iface;
    };

  policyPointTraversal =
    { relationId
    , action
    , direction
    , fromIface
    , toIface
    , policyPoint ? "policy-router"
    ,
    }:
    {
      inherit relationId action direction policyPoint;
      sourceInterface = fromIface.runtimeIfName;
      destinationInterface = toIface.runtimeIfName;
      nonBypass = true;
      source = interfaceScope fromIface;
      destination = interfaceScope toIface;
    };

  relationHandoff =
    { relationId
    , action
    , direction
    , fromIface
    , toIface
    , policyPoint ? "policy-router"
    ,
    }:
    {
      sourceScope = interfaceScope fromIface;
      destinationScope = interfaceScope toIface;
      candidateEgress = candidateEgress toIface;
      policyPointTraversal = policyPointTraversal {
        inherit relationId action direction fromIface toIface policyPoint;
      };
    };

  selectorRelationId = direction: fromIface: toIface:
    let
      fromScope = selectorScope fromIface;
      toScope = selectorScope toIface;
      fromLane = lane fromIface;
      toLane = lane toIface;
      access =
        if (fromLane.access or null) != null then
          fromLane.access
        else if (toLane.access or null) != null then
          toLane.access
        else
          "no-access";
      uplink =
        if (fromLane.uplink or null) != null then
          fromLane.uplink
        else if (toLane.uplink or null) != null then
          toLane.uplink
        else
          builtins.concatStringsSep "-" (uplinks fromIface ++ uplinks toIface);
      uplinkPart = if uplink == "" then "fabric" else uplink;
    in
    "selector-handoff-${direction}--${access}--${fromScope.relationPurpose}-to-${toScope.relationPurpose}--${uplinkPart}";

  selectorRuntimeRuleAudit =
    { relationId
    , direction
    , fromIface
    , toIface
    , trafficType ? "any"
    , decomposed ? false
    ,
    }:
    {
      relationId = relationId;
      comment = relationId;
      trafficType = trafficType;
      direction = direction;
      from = selectorScope fromIface;
      to = selectorScope toIface;
      relationCardinality = {
        unit = "selector-forwarding-rule";
        decomposition =
          if decomposed then
            "decomposed-by-selector-interface-scope"
          else
            "one-rule-per-selector-handoff-direction";
        decomposed = decomposed;
      };
    }
    // relationHandoff {
      inherit relationId direction fromIface toIface;
      action = "accept";
      policyPoint = "selector";
    };

  selectorPairAudit = direction: fromIface: toIface:
    selectorRuntimeRuleAudit {
      relationId = selectorRelationId direction fromIface toIface;
      inherit direction fromIface toIface;
    };

  selectorPairRule = fromIface: toIface: [
    ({
      action = "accept";
      fromInterface = fromIface.runtimeIfName;
      toInterface = toIface.runtimeIfName;
      applyTcpMssClamp = true;
    } // selectorPairAudit "forward" fromIface toIface)
    ({
      action = "accept";
      fromInterface = toIface.runtimeIfName;
      toInterface = fromIface.runtimeIfName;
      applyTcpMssClamp = false;
    } // selectorPairAudit "reverse" toIface fromIface)
  ];

  selectorPairRuleWithRuntimeOriginScope = runtimeOriginSourcePrefixes: fromIface: toIface: [
    (withSourcePrefixes
      ({
        action = "accept";
        fromInterface = fromIface.runtimeIfName;
        toInterface = toIface.runtimeIfName;
        applyTcpMssClamp = true;
      } // selectorPairAudit "forward-runtime-origin" fromIface toIface)
      (sourcePrefixesReachableVia runtimeOriginSourcePrefixes fromIface))
    (withSourcePrefixes
      ({
        action = "accept";
        fromInterface = toIface.runtimeIfName;
        toInterface = fromIface.runtimeIfName;
        applyTcpMssClamp = false;
      } // selectorPairAudit "reverse-runtime-origin" toIface fromIface)
      (sourcePrefixesReachableVia runtimeOriginSourcePrefixes toIface))
  ];
}
