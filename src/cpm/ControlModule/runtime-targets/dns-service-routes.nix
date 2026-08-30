{ lib, common, ipam }:

let
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;

  routeIntent = route: attrsOrEmpty (route.intent or null);
  viaFieldFor = family: if family == 4 then "via4" else "via6";
  addrFieldFor = family: if family == 4 then "addr4" else "addr6";

  cidrContainsIPv6 =
    cidr: address:
    let
      parsedCidr = if builtins.isString cidr then ipam.splitCIDR cidr else null;
      cidrAddr =
        if parsedCidr == null then null else ipam.parseIPv6 parsedCidr.addr;
      addr = if builtins.isString address then ipam.parseIPv6 address else null;
      take = count: values: builtins.genList (idx: builtins.elemAt values idx) count;
      fullHextets = if parsedCidr == null then 0 else builtins.div parsedCidr.prefixLen 16;
      partialBits = if parsedCidr == null then 0 else lib.mod parsedCidr.prefixLen 16;
      p2p127Match =
        parsedCidr != null
        && parsedCidr.prefixLen == 127
        && take 7 cidrAddr == take 7 addr
        && builtins.div (builtins.elemAt cidrAddr 7) 2 == builtins.div (builtins.elemAt addr 7) 2;
    in
    parsedCidr != null
    && cidrAddr != null
    && addr != null
    && (
      if parsedCidr.prefixLen == 127 then
        p2p127Match
      else if partialBits == 0 then
        take fullHextets cidrAddr == take fullHextets addr
      else
        false
    );

  gatewayReachableFromInterface =
    family: iface: route:
    let
      viaField = viaFieldFor family;
      addrField = addrFieldFor family;
      via = route.${viaField} or null;
      cidr = iface.${addrField} or null;
    in
    if !(builtins.isString via) || via == "" then
      false
    else if family == 4 then
      common.cidrContainsAddress cidr via
    else
      cidrContainsIPv6 cidr via;

  hasP2PPrefixLength = dst:
    builtins.isString dst
    && (
      # Only the point-to-point /31 (IPv4) and /127 (IPv6) subnets are p2p
      # links. A /32 or /128 is a distinct host route (a router loopback or a
      # service address), not a p2p subnet, and must not be filtered out.
      builtins.match ".*/31" dst != null
      || builtins.match ".*/127" dst != null
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
          (builtins.filter (gatewayReachableFromInterface family iface) (listOrEmpty routes));
    in
    {
      ipv4 = missing 4 (extraRoutes.ipv4 or [ ]);
      ipv6 = missing 6 (extraRoutes.ipv6 or [ ]);
    };

  interfaceByRuntimeName =
    interfaces:
    builtins.listToAttrs (
      builtins.concatLists (builtins.map
        (ifName:
        let
          iface = interfaces.${ifName};
          runtimeIfName = iface.runtimeIfName or null;
        in
        if builtins.isString runtimeIfName && runtimeIfName != "" then
          [{ name = runtimeIfName; value = { inherit ifName iface; }; }]
        else
          [ ])
        (builtins.attrNames interfaces))
    );

  dnsRules =
    rules:
    builtins.filter
      (rule:
      (rule.action or null) == "accept"
      && (rule.trafficType or null) == "dns"
      && ((attrsOrEmpty (rule.from or null)).kind or null) != "service"
      && ((attrsOrEmpty (rule.to or null)).kind or null) == "service")
      (listOrEmpty rules);

  ingressLaneFor =
    iface:
    attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);

  laneKindFor =
    iface:
    (ingressLaneFor iface).kind or null;

  withIngressPolicyLane =
    fromIface: route:
    let
      lane = ingressLaneFor fromIface;
      intent = attrsOrEmpty (route.intent or null);
    in
    if lane == { } then
      route
    else
      route // {
        inherit lane;
        policyOnly = true;
        reason = route.reason or "policy-table-service-reachability";
        intent = intent // {
          policyTableComplement = true;
          source = "service-ingress-lane";
        };
      };

  tagIngressRoutes =
    fromIface: routes: {
      ipv4 = builtins.map (withIngressPolicyLane fromIface) (listOrEmpty (routes.ipv4 or null));
      ipv6 = builtins.map (withIngressPolicyLane fromIface) (listOrEmpty (routes.ipv6 or null));
    };

  serviceEndpointRoutes = import ./service-endpoint-routes.nix {
    inherit
      lib
      common
      ipam
      hasP2PPrefixLength
      routeIntent
      ;
  };
  inherit (serviceEndpointRoutes)
    endpointRoutes
    externalServiceRules
    serviceRecords
    ;

  addRoutesForTarget =
    services: target: forwarding:
    let
      servicesByName = serviceRecords services;
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
                fromIface = byRuntime.${fromName}.iface;
                toIfName = byRuntime.${toName}.ifName;
                toIface = byRuntime.${toName}.iface;
                extraRoutes = tagIngressRoutes fromIface (routesFromInterface toIface);
                previous = attrsOrEmpty (acc.${toIfName} or null);
              in
              acc // { ${toIfName} = mergeRoutes previous extraRoutes; })
          { }
          (dnsRules (forwarding.rules or [ ]));
      endpointExtraByIf =
        builtins.foldl'
          (acc: rule:
            let
              serviceName = (attrsOrEmpty (rule.to or null)).name or null;
              fromName = rule.fromInterface or null;
              toName = rule.toInterface or null;
            in
            if
              !(builtins.hasAttr fromName byRuntime)
              || !(builtins.hasAttr toName byRuntime)
              || !(builtins.hasAttr serviceName servicesByName)
            then
              acc
            else
              let
                fromIface = byRuntime.${fromName}.iface;
                fromIfName = byRuntime.${fromName}.ifName;
                toIfName = byRuntime.${toName}.ifName;
                toIface = byRuntime.${toName}.iface;
                service = servicesByName.${serviceName};
                serviceFacingRoute =
                  (target.role or null) == "policy"
                  || (laneKindFor fromIface == "uplink" && laneKindFor toIface == "access-uplink");
                routeIfName =
                  if serviceFacingRoute then toIfName else fromIfName;
                routeIface =
                  if serviceFacingRoute then toIface else fromIface;
                extraRoutes = tagIngressRoutes fromIface (dropRoutesAlreadyOnInterface routeIface {
                  ipv4 = endpointRoutes 4 rule service { inherit fromIface toIface routeIface; };
                  ipv6 = endpointRoutes 6 rule service { inherit fromIface toIface routeIface; };
                });
                previous = attrsOrEmpty (acc.${routeIfName} or null);
              in
              acc // { ${routeIfName} = mergeRoutes previous extraRoutes; })
          extraByIf
          (externalServiceRules (forwarding.rules or [ ]));
      updatedInterfaces =
        builtins.mapAttrs
          (ifName: iface:
            if !(builtins.hasAttr ifName endpointExtraByIf) then
              iface
            else
              iface // { routes = mergeRoutes (attrsOrEmpty (iface.routes or null)) endpointExtraByIf.${ifName}; })
          interfaces;
    in
    if interfaces == { } || endpointExtraByIf == { } then
      target
    else
      target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; };
in
{ firewallIntent
, normalizedRuntimeTargets
, services ? [ ]
,
}:
builtins.mapAttrs
  (targetName: target:
  if builtins.hasAttr targetName (firewallIntent.forwardingByTarget or { }) then
    addRoutesForTarget services target firewallIntent.forwardingByTarget.${targetName}
  else
    target)
  normalizedRuntimeTargets
