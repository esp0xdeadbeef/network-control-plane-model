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
    builtins.attrValues (
      builtins.listToAttrs (
        map (prefix: {
          name = "${builtins.toString (prefix.family or "")}|${prefix.prefix or ""}";
          value = prefix;
        }) (
          builtins.filter
            (prefix: builtins.any (routeMatchesPrefix prefix) routes)
            runtimeOriginSourcePrefixes
        )
      )
    );

  hasDefaultRoute =
    iface:
    builtins.any (
      route:
      builtins.isAttrs route && ((route.dst or null) == "0.0.0.0/0" || (route.dst or null) == "::/0")
    ) (routeList iface);

  hasAnyRuntimeOriginRoute =
    runtimeOriginSourcePrefixes: iface:
    sourcePrefixesReachableVia runtimeOriginSourcePrefixes iface != [ ];

  runtimeOriginDefaultForwardRules =
    runtimeOriginSourcePrefixes: interfaces:
    let
      defaultIfaces = builtins.filter hasDefaultRoute interfaces;
      sourceScopeFor =
        iface:
        let
          localScope = sourcePrefixesReachableVia runtimeOriginSourcePrefixes iface;
        in
        if localScope != [ ] then localScope else runtimeOriginSourcePrefixes;
    in
    builtins.concatLists (
      map (
        fromIface:
        let
          sourcePrefixes = sourceScopeFor fromIface;
          fromAccess = laneAccess fromIface;
          defaultIfacesForIngress =
            let
              sameAccessDefaults = builtins.filter (
                toIface: fromAccess != null && laneAccess toIface == fromAccess
              ) defaultIfaces;
            in
            if sameAccessDefaults != [ ] then sameAccessDefaults else defaultIfaces;
        in
        if sourcePrefixes == [ ] then
          [ ]
        else
          map (
            toIface:
            withSourcePrefixes {
              action = "accept";
              relationId = "runtime-origin-egress";
              intent = {
                kind = "runtime-origin-egress";
                source = "loopback-runtime-identity";
                stage = "selector-default-egress";
              };
              fromInterface = fromIface.runtimeIfName;
              toInterface = toIface.runtimeIfName;
              applyTcpMssClamp = false;
            } sourcePrefixes
          ) (builtins.filter (toIface: toIface.runtimeIfName != fromIface.runtimeIfName) defaultIfacesForIngress)
      ) interfaces
    );

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

  selectorPairRule = fromIface: toIface: [
    {
      action = "accept";
      fromInterface = fromIface.runtimeIfName;
      toInterface = toIface.runtimeIfName;
      applyTcpMssClamp = true;
    }
    {
      action = "accept";
      fromInterface = toIface.runtimeIfName;
      toInterface = fromIface.runtimeIfName;
      applyTcpMssClamp = false;
    }
  ];

  selectorPairRuleWithRuntimeOriginScope = runtimeOriginSourcePrefixes: fromIface: toIface: [
    (withSourcePrefixes {
      action = "accept";
      fromInterface = fromIface.runtimeIfName;
      toInterface = toIface.runtimeIfName;
      applyTcpMssClamp = true;
    } (sourcePrefixesReachableVia runtimeOriginSourcePrefixes fromIface))
    (withSourcePrefixes {
      action = "accept";
      fromInterface = toIface.runtimeIfName;
      toInterface = fromIface.runtimeIfName;
      applyTcpMssClamp = false;
    } (sourcePrefixesReachableVia runtimeOriginSourcePrefixes toIface))
  ];
}
