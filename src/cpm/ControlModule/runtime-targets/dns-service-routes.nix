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

  # Is the service's own address on this interface, i.e. is this node the endpoint
  # rather than a transit hop? Only then is the ingress interface the right place
  # for the endpoint route.
  ownsServiceAddress =
    service: iface:
    let
      addr4 = iface.addr4 or null;
      svc = (attrsOrEmpty (service.intent or null)).addresses or (service.addresses or [ ]);
      bare = a: builtins.head (lib.splitString "/" a);
      wanted = listOrEmpty svc;
    in
    addr4 != null && builtins.any (a: bare a == bare addr4) wanted;

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

  # The service-ingress-lane tag marks a route whose next hop is the ingress peer.
  # That is the way onward only at a relation's FIRST transit hop; on the policy
  # node the same /32 is more specific than the fabric /31 that names the real next
  # hop and reflects the packet back (measured on the cobalt HAT: right on the
  # downstream-selector via 10.1.0.25, wrong on policy where it beat
  # `10.1.0.16/31 via 10.1.0.41 dev up-clients`).
  #
  # `targetIsPolicy` lets the callers suppress the tag there, so the route is still
  # offered but without the policy-table complement marking that makes the renderer
  # keep it ahead of the fabric route.
  tagIngressRoutes =
    targetIsPolicy: fromIface: routes: {
      # On the policy node these routes must not be emitted at all, not merely
      # untagged: a plain `/32` for the resolver address still outranks the fabric
      # `/31` that names the real next hop, so the packet is reflected whether or
      # not it carries the complement marking. An earlier version of this gate only
      # dropped the tag and the rendered routes were unchanged (5 per node).
      ipv4 = if targetIsPolicy then
        [ ]
      else
        builtins.map (withIngressPolicyLane fromIface) (listOrEmpty (routes.ipv4 or null));
      ipv6 = if targetIsPolicy then
        [ ]
      else
        builtins.map (withIngressPolicyLane fromIface) (listOrEmpty (routes.ipv6 or null));
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
      targetIsPolicy = (target.role or null) == "policy";
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
                extraRoutes = tagIngressRoutes targetIsPolicy fromIface (routesFromInterface toIface);
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
                # The endpoint route's next hop is `routeIface`'s peer, so this
                # choice decides the gateway. Both ends of a resolver relation are
                # `service` kind, so `laneKindFor` does not tell ingress from egress
                # and a transit hop fell through to the ingress interface -- taking
                # the ingress peer as the gateway and pointing the resolver route
                # back at the node it came from.
                #
                # Measured on the cobalt HAT: the downstream-selector rendered
                # `10.1.0.16 via 10.1.0.0 dev pacds` (pacds is 10.1.0.1, the access
                # side) while the resolver is only reachable across pdspaac
                # (10.1.0.24, peer 10.1.0.25).
                serviceFacingRoute =
                  (target.role or null) == "policy"
                  || (laneKindFor fromIface == "uplink" && laneKindFor toIface == "access-uplink")
                  || (fromIfName != toIfName && !ownsServiceAddress service fromIface);
                routeIfName =
                  if serviceFacingRoute then toIfName else fromIfName;
                routeIface =
                  if serviceFacingRoute then toIface else fromIface;
                extraRoutes = tagIngressRoutes targetIsPolicy fromIface (dropRoutesAlreadyOnInterface routeIface {
                  ipv4 = endpointRoutes 4 rule service { inherit fromIface toIface routeIface; };
                  ipv6 = endpointRoutes 6 rule service { inherit fromIface toIface routeIface; };
                });
                previous = attrsOrEmpty (acc.${routeIfName} or null);
              in
              acc // { ${routeIfName} = mergeRoutes previous extraRoutes; })
          extraByIf
          (externalServiceRules (forwarding.rules or [ ]));
      # FS-540-HDS-010-SDS-010-SMS-020 requester-lane authority is independent
      # of the provider-facing rule class: a tenant-set/service relation is the
      # requester leg the resolver relation admitted, and it must carry the
      # emitted endpoint prefix on that requester lane with the lane's modelled
      # next hop.
      requesterServiceRules = builtins.filter
        (rule:
          (rule.action or null) == "accept"
          && ((attrsOrEmpty (rule.to or null)).kind or null) == "service"
          # Rules already handled by the provider-facing pass must not be
          # emitted a second time on the same interface (FS-315: no duplicate
          # route meaning).
          && ((attrsOrEmpty (rule.from or null)).kind or null) != "external")
        (listOrEmpty (forwarding.rules or [ ]));
      requesterExtraByIf = builtins.foldl'
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
            || fromName == toName
            # Only a downstream access lane may carry requester-lane authority.
            # An uplink lane is an exit surface, and putting an internal
            # resolver endpoint on it would create a return route for a
            # runtime-origin source prefix (FS-550 leak prevention, SMS-040).
            || builtins.elem (laneKindFor byRuntime.${fromName}.iface) [
              "uplink"
              "access-uplink"
            ]
          then
            acc
          else
            let
              fromIface = byRuntime.${fromName}.iface;
              fromIfName = byRuntime.${fromName}.ifName;
              service = servicesByName.${serviceName};
              requesterRoutes = tagIngressRoutes targetIsPolicy fromIface (dropRoutesAlreadyOnInterface fromIface {
                ipv4 = endpointRoutes 4 rule service {
                  fromIface = fromIface;
                  toIface = fromIface;
                  routeIface = fromIface;
                };
                ipv6 = endpointRoutes 6 rule service {
                  fromIface = fromIface;
                  toIface = fromIface;
                  routeIface = fromIface;
                };
              });
              # The destination-facing pass may already have put the same
              # endpoint prefix on this interface; never emit a second atom for
              # the same destination (FS-315: no duplicate route meaning).
              alreadyThere =
                family: routes:
                builtins.filter
                  (route:
                    !(builtins.any
                      (existing:
                      (existing.dst or null) == (route.dst or null)
                      && (existing.via4 or existing.via6 or null) == (route.via4 or route.via6 or null))
                      (listOrEmpty ((attrsOrEmpty (acc.${fromIfName} or null)).${family} or null))))
                  routes;
              deduped = {
                ipv4 = alreadyThere "ipv4" (requesterRoutes.ipv4 or [ ]);
                ipv6 = alreadyThere "ipv6" (requesterRoutes.ipv6 or [ ]);
              };
            in
            if requesterRoutes == { } || (deduped.ipv4 == [ ] && deduped.ipv6 == [ ]) then
              acc
            else
              acc // {
                ${fromIfName} = mergeRoutes (attrsOrEmpty (acc.${fromIfName} or null)) deduped;
              })
        endpointExtraByIf
        requesterServiceRules;
      mergeByIf =
        left: right:
        builtins.foldl'
          (acc: name:
          acc // {
            ${name} = mergeRoutes (attrsOrEmpty (acc.${name} or null)) (attrsOrEmpty (right.${name} or null));
          })
          left
          (builtins.attrNames right);
      allExtraByIf = mergeByIf endpointExtraByIf requesterExtraByIf;
      updatedInterfaces =
        builtins.mapAttrs
          (ifName: iface:
            if !(builtins.hasAttr ifName allExtraByIf) then
              iface
            else
              iface // { routes = mergeRoutes (attrsOrEmpty (iface.routes or null)) allExtraByIf.${ifName}; })
          interfaces;
    in
    if interfaces == { } || allExtraByIf == { } then
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
