{ lib, common }:

let
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;

  routeIntent = route: attrsOrEmpty (route.intent or null);
  hasP2PPrefixLength = dst:
    builtins.isString dst
    && (
      builtins.match ".*/3[12]" dst != null
      || builtins.match ".*/12[78]" dst != null
    );

  dnsServiceRoute = route:
    builtins.isAttrs route
    && ((routeIntent route).kind or null) == "internal-reachability"
    && !hasP2PPrefixLength (route.dst or null);

  routesFromInterface = iface: {
    ipv4 = builtins.map
      (route: route // { intent = { kind = "service-dns-reachability"; }; })
      (builtins.filter dnsServiceRoute (listOrEmpty ((attrsOrEmpty (iface.routes or null)).ipv4 or null)));
    ipv6 = builtins.map
      (route: route // { intent = { kind = "service-dns-reachability"; }; })
      (builtins.filter dnsServiceRoute (listOrEmpty ((attrsOrEmpty (iface.routes or null)).ipv6 or null)));
  };

  sameKernelRoute = family: left: right:
    let
      viaField = if family == 4 then "via4" else "via6";
    in
    (left.dst or null) == (right.dst or null)
    && (left.${viaField} or null) == (right.${viaField} or null);

  dropRoutesAlreadyOnInterface =
    iface: extraRoutes:
    let
      existingRoutes = attrsOrEmpty (iface.routes or null);
      missing = family: routes:
        builtins.filter
          (route:
            !builtins.any
              (existing: sameKernelRoute family route existing)
              (listOrEmpty (existingRoutes.${if family == 4 then "ipv4" else "ipv6"} or null)))
          (listOrEmpty routes);
    in
    {
      ipv4 = missing 4 (extraRoutes.ipv4 or [ ]);
      ipv6 = missing 6 (extraRoutes.ipv6 or [ ]);
    };

  interfaceByRuntimeName =
    interfaces:
    builtins.listToAttrs (
      lib.concatMap
        (ifName:
        let
          iface = interfaces.${ifName};
          runtimeIfName = iface.runtimeIfName or null;
        in
        if builtins.isString runtimeIfName && runtimeIfName != "" then
          [{ name = runtimeIfName; value = { inherit ifName iface; }; }]
        else
          [ ])
        (builtins.attrNames interfaces)
    );

  dnsRules =
    rules:
    builtins.filter
      (rule:
      (rule.action or null) == "accept"
      && (rule.trafficType or null) == "dns"
      && ((attrsOrEmpty (rule.from or null)).kind or null) == "external"
      && ((attrsOrEmpty (rule.to or null)).kind or null) == "service")
      (listOrEmpty rules);

  addRoutesForTarget =
    target: forwarding:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      byRuntime = interfaceByRuntimeName interfaces;
      extraByIf =
        builtins.foldl'
          (acc: rule:
            let
              fromName = rule.fromInterface or null;
              toName = rule.toInterface or null;
            in
            if !(builtins.hasAttr fromName byRuntime) || !(builtins.hasAttr toName byRuntime) then
              acc
            else
              let
                fromIfName = byRuntime.${fromName}.ifName;
                fromIface = byRuntime.${fromName}.iface;
                toIface = byRuntime.${toName}.iface;
                extraRoutes = dropRoutesAlreadyOnInterface fromIface (routesFromInterface toIface);
                previous = attrsOrEmpty (acc.${fromIfName} or null);
              in
              acc // { ${fromIfName} = mergeRoutes previous extraRoutes; })
          { }
          (dnsRules (forwarding.rules or [ ]));
      updatedInterfaces =
        builtins.mapAttrs
          (ifName: iface:
            if !(builtins.hasAttr ifName extraByIf) then
              iface
            else
              iface // { routes = mergeRoutes (attrsOrEmpty (iface.routes or null)) extraByIf.${ifName}; })
          interfaces;
    in
    if interfaces == { } || extraByIf == { } then
      target
    else
      target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; };
in
{ firewallIntent
, normalizedRuntimeTargets
,
}:
builtins.mapAttrs
  (targetName: target:
  if builtins.hasAttr targetName (firewallIntent.forwardingByTarget or { }) then
    addRoutesForTarget target firewallIntent.forwardingByTarget.${targetName}
  else
    target)
  normalizedRuntimeTargets
