{ lib
, helpers
, common
, policyDerivedDnsAllowedClassesForListeners
, policyDerivedDnsForwardersForListeners
, policyDerivedDnsUpstreamRecordsForListeners ? (_listeners: [ ])
,
}:

let
  inherit (common) attrsOrEmpty failInventory listOrEmpty;

  publicResolvers = {
    "1.1.1.1" = true;
    "1.0.0.1" = true;
    "8.8.8.8" = true;
    "8.8.4.4" = true;
    "9.9.9.9" = true;
    "2606:4700:4700::1111" = true;
    "2606:4700:4700::1001" = true;
    "2001:4860:4860::8888" = true;
    "2001:4860:4860::8844" = true;
    "2620:fe::fe" = true;
  };

  isPublicResolver = forwarder: builtins.hasAttr forwarder publicResolvers;
  forwarderFamily =
    forwarder:
    if builtins.match ".*:.*" forwarder != null then "ipv6" else "ipv4";

  dnsService = import ../../Unit/runtime-services/dns.nix {
    inherit lib helpers;
    inherit (common) failInventory;
  };
  inherit (dnsService) normalizeDnsService;

  routeContractForForwarder = forwarder: {
    dst = forwarder;
    source = "dns-service";
  };

  routeContractForUpstreamResolver = resolver:
    attrsOrEmpty resolver
    // {
      source = (attrsOrEmpty resolver).source or "provider-access-dns";
    };

  routeForForwarder = forwarder: {
    dst = forwarder;
    proto = "service";
    intent = {
      kind = "dns-forwarder-reachability";
      source = "dns-service";
    };
  };

  routeContractForListener = address: {
    dst = address;
    source = "router-self";
    scope = "local-access";
  };

  trafficClassForModeledResolver = target: route: {
    kind = "public-dns-traffic-classification";
    trafficClass = "modeled-resolver-traffic";
    resolverDestination = route.dst or route.destination;
    requesterScope = target.placement.target or target.logicalNode.name or "access";
    egressSurface = route.scope or route.class or route.source or "modeled-resolver";
    protocol = "tcp-udp";
    port = "53";
    dnsPolicy = "modeled-resolver-relationship";
    egressPolicy = "not-direct-public-dns";
  };

  trafficClassForDeniedDirectPublicDns = target: allowedUpstreamClasses: resolverCidr: {
    kind = "public-dns-traffic-classification";
    trafficClass = "denied-direct-public-dns";
    resolverDestination = resolverCidr;
    requesterScope = target.placement.target or target.logicalNode.name or "access";
    egressSurface =
      if builtins.elem "explicit-egress-default" allowedUpstreamClasses then
        "explicit-egress-default"
      else
        "no-modeled-public-egress";
    protocol = "tcp-udp";
    port = "53";
    dnsPolicy = "direct-public-dns-forbidden";
    egressPolicy =
      if builtins.elem "explicit-egress-default" allowedUpstreamClasses then
        "egress-allowed"
      else
        "egress-not-allowed";
  };

  trafficClassForUnrelatedPayload = target: allowedUpstreamClasses: resolverCidr: {
    kind = "public-dns-traffic-classification";
    trafficClass = "unrelated-payload";
    resolverDestination = resolverCidr;
    requesterScope = target.placement.target or target.logicalNode.name or "access";
    egressSurface =
      if builtins.elem "explicit-egress-default" allowedUpstreamClasses then
        "explicit-egress-default"
      else
        "no-modeled-public-egress";
    protocol = "non-dns";
    port = "not-53";
    dnsPolicy = "not-dns-traffic";
    egressPolicy =
      if builtins.elem "explicit-egress-default" allowedUpstreamClasses then
        "egress-allowed"
      else
        "egress-not-allowed";
  };

  optionalString = value:
    if builtins.isString value && value != "" then [ value ] else [ ];

  advertisedDnsListeners = advertisements:
    lib.unique (
      lib.concatMap (entry: listOrEmpty (entry.dnsServers or null)) (listOrEmpty (advertisements.dhcp4 or null))
      ++ lib.concatMap (entry: listOrEmpty (entry.rdnss or null)) (listOrEmpty (advertisements.ipv6Ra or null))
    );

  advertisedDnsSources = advertisements:
    lib.unique (
      lib.concatMap (entry: optionalString (entry.subnet or null)) (listOrEmpty (advertisements.dhcp4 or null))
      ++ lib.concatMap (entry: listOrEmpty (entry.prefixes or null)) (listOrEmpty (advertisements.ipv6Ra or null))
    );

  runtimeTargetPath = target:
    "runtimeTargets.${target.placement.target or target.logicalNode.name or "access"}";

  addForwarderRoutes =
    target: forwarders:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      routesByFamily = {
        ipv4 = builtins.map routeForForwarder (builtins.filter (f: forwarderFamily f == "ipv4") forwarders);
        ipv6 = builtins.map routeForForwarder (builtins.filter (f: forwarderFamily f == "ipv6") forwarders);
      };
      updatedInterfaces =
        builtins.mapAttrs
          (_: iface:
            if (iface.sourceKind or null) != "p2p" then
              iface
            else
              let
                routes = attrsOrEmpty (iface.routes or null);
              in
              iface
              // {
                routes = {
                  ipv4 = listOrEmpty (routes.ipv4 or null) ++ routesByFamily.ipv4;
                  ipv6 = listOrEmpty (routes.ipv6 or null) ++ routesByFamily.ipv6;
                };
              })
          interfaces;
    in
    if interfaces == { } || forwarders == [ ] then
      target
    else
      target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; };

  synthesizeRouterSelfDns = target:
    let
      advertisements = attrsOrEmpty (target.advertisements or null);
      listeners = advertisedDnsListeners advertisements;
      sources = advertisedDnsSources advertisements;
      existingServices = attrsOrEmpty (target.services or null);
      hasModeledDnsPolicy = existingServices ? dns;
      existingDns = attrsOrEmpty (existingServices.dns or null);
      existingForwarders = listOrEmpty (existingDns.forwarders or null);
      existingUpstreamResolvers = listOrEmpty (existingDns.upstreamResolvers or null);
      derivedUpstreamResolvers = policyDerivedDnsUpstreamRecordsForListeners listeners;
      upstreamResolvers =
        if existingUpstreamResolvers != [ ] then
          existingUpstreamResolvers
        else
          derivedUpstreamResolvers;
      derivedForwarders = policyDerivedDnsForwardersForListeners listeners;
      forwarders =
        if upstreamResolvers != [ ] then
          [ ]
        else if existingForwarders != [ ] then
          existingForwarders
        else
          derivedForwarders;
      # GAMP: FS-540-HDS-010-SDS-010-SMS-035 — filter self-referential forwarders
      nonLoopbackListeners = builtins.filter (addr: addr != "127.0.0.1" && addr != "::1") listeners;
      selfRefForwarders = builtins.filter (f: builtins.elem f nonLoopbackListeners) forwarders;
      safeForwarders =
        if selfRefForwarders != [ ] then
          builtins.filter (f: !(builtins.elem f nonLoopbackListeners)) forwarders
        else
          forwarders;
      allowedUpstreamClasses =
        lib.unique (
          listOrEmpty (existingDns.allowedUpstreamClasses or null)
          ++ policyDerivedDnsAllowedClassesForListeners listeners
        );
      localContracts = builtins.map routeContractForListener listeners;
      mergedDns =
        existingDns
        // {
          listen = lib.unique (listOrEmpty (existingDns.listen or null) ++ listeners);
          allowFrom = lib.unique (listOrEmpty (existingDns.allowFrom or null) ++ sources);
          blockDirectEgress = true;
          directEgressBlockedTenants = listOrEmpty (existingDns.directEgressBlockedTenants or null);
          forwarders = safeForwarders;
          upstreamResolvers = upstreamResolvers;
          allowedUpstreamClasses = allowedUpstreamClasses;
          outgoingInterfaces =
            if listOrEmpty (existingDns.outgoingInterfaces or null) != [ ] then
              listOrEmpty (existingDns.outgoingInterfaces or null)
            else if safeForwarders != [ ] then
              builtins.filter (addr: addr != "127.0.0.1" && addr != "::1") listeners
            else
              [ ];
          routeContracts = lib.unique (listOrEmpty (existingDns.routeContracts or null) ++ localContracts);
          policyMatrix = lib.unique (listOrEmpty (existingDns.policyMatrix or null) ++ localContracts);
        };
    in
    if (target.role or null) != "access" || listeners == [ ] then
      target
    else if !hasModeledDnsPolicy then
      failInventory
        "${runtimeTargetPath target}.services.dns"
        "missing modeled DNS policy for resolver advertisement; define services.dns before renderer-facing advertisement output"
    else
      target
      // {
        services = (attrsOrEmpty (target.services or null)) // {
          dns = (normalizeDnsService "${runtimeTargetPath target}.services" mergedDns) // {
            blockDirectEgress = true;
          };
        };
      };
in
target:
let
  targetWithDns = synthesizeRouterSelfDns target;
  dns = attrsOrEmpty (targetWithDns.services.dns or null);
  forwarders = listOrEmpty (dns.forwarders or null);
  upstreamResolverContracts = builtins.map routeContractForUpstreamResolver (listOrEmpty (dns.upstreamResolvers or null));
  suppressForwarderContracts = upstreamResolverContracts != [ ] && forwarders == [ ];
  dnsWithUpstreamResolverContracts =
    if upstreamResolverContracts == [ ] then
      dns
    else
      dns
      // {
        routeContracts = listOrEmpty (dns.routeContracts or null) ++ upstreamResolverContracts;
        policyMatrix = listOrEmpty (dns.policyMatrix or null) ++ upstreamResolverContracts;
      };
  dnsContracts =
    if forwarders == [ ] then
      dnsWithUpstreamResolverContracts
    else
      let
        allowedUpstreamClasses =
          lib.unique (
            listOrEmpty (dns.allowedUpstreamClasses or null)
            ++ (if builtins.any isPublicResolver forwarders then [ "explicit-egress-default" ] else [ ])
          );
        roles = attrsOrEmpty (dns.roles or null);
        recursionRole = attrsOrEmpty (roles.recursion or null);
      in
      dns
      // {
        allowedUpstreamClasses = allowedUpstreamClasses;
        roles = roles // { recursion = recursionRole // { allowedUpstreamClasses = allowedUpstreamClasses; }; };
        routeContracts = listOrEmpty (dns.routeContracts or null) ++ upstreamResolverContracts ++ builtins.map routeContractForForwarder forwarders;
        policyMatrix = listOrEmpty (dns.policyMatrix or null) ++ upstreamResolverContracts ++ builtins.map routeContractForForwarder forwarders;
      };
  dnsWithTrafficClassifications =
    let
      allowedUpstreamClasses = listOrEmpty (dnsContracts.allowedUpstreamClasses or null);
      modeledResolverRoutes =
        builtins.filter
          (route: builtins.isAttrs route && (route.source or null) == "router-self" && (route.dst or null) != null)
          (listOrEmpty (dnsContracts.routeContracts or null));
      modeledResolverClasses =
        builtins.map (trafficClassForModeledResolver targetWithDnsContracts) modeledResolverRoutes;
      deniedResolverCidrs = listOrEmpty (dnsContracts.deniedResolverCidrs or null);
      emitsDirectPublicDnsDenial =
        ((attrsOrEmpty (dnsContracts.killSwitch or null)).blockPublicResolvers or false)
        && deniedResolverCidrs != [ ];
      deniedDirectClasses =
        if emitsDirectPublicDnsDenial then
          builtins.map (trafficClassForDeniedDirectPublicDns targetWithDnsContracts allowedUpstreamClasses) deniedResolverCidrs
        else
          [ ];
      unrelatedPayloadClasses =
        if deniedResolverCidrs != [ ] then
          builtins.map (trafficClassForUnrelatedPayload targetWithDnsContracts allowedUpstreamClasses) deniedResolverCidrs
        else
          [ ];
      publicDnsTrafficClassifications =
        modeledResolverClasses ++ deniedDirectClasses ++ unrelatedPayloadClasses;
    in
    if publicDnsTrafficClassifications == [ ] then
      dnsContracts
    else
      dnsContracts // { inherit publicDnsTrafficClassifications; };
  targetWithDnsContracts =
    targetWithDns
    // {
      services = (attrsOrEmpty (targetWithDns.services or null)) // { dns = dnsWithTrafficClassifications; };
    };
in
if dns == { } then
  targetWithDns
else if suppressForwarderContracts then
  targetWithDnsContracts
else if forwarders == [ ] then
  targetWithDnsContracts
else if (targetWithDns.role or null) != "access" then
  targetWithDnsContracts
else
  addForwarderRoutes
    targetWithDnsContracts
    forwarders
