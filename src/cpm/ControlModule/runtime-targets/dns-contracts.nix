{ lib
, helpers
, common
, policyDerivedDnsAllowedClassesForListeners
, policyDerivedDnsForwardersForListeners
,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

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
      existingDns = attrsOrEmpty (target.services.dns or null);
      existingForwarders = listOrEmpty (existingDns.forwarders or null);
      derivedForwarders = policyDerivedDnsForwardersForListeners listeners;
      forwarders = if existingForwarders != [ ] then existingForwarders else derivedForwarders;
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
          forwarders = forwarders;
          allowedUpstreamClasses = allowedUpstreamClasses;
          outgoingInterfaces =
            if listOrEmpty (existingDns.outgoingInterfaces or null) != [ ] then
              listOrEmpty (existingDns.outgoingInterfaces or null)
            else if forwarders != [ ] then
              builtins.filter (addr: addr != "127.0.0.1" && addr != "::1") listeners
            else
              [ ];
          routeContracts = lib.unique (listOrEmpty (existingDns.routeContracts or null) ++ localContracts);
          policyMatrix = lib.unique (listOrEmpty (existingDns.policyMatrix or null) ++ localContracts);
        };
    in
    if (target.role or null) != "access" || listeners == [ ] then
      target
    else
      target
      // {
        services = (attrsOrEmpty (target.services or null)) // {
          dns = (normalizeDnsService "runtimeTargets.${target.logicalNode.name or "access"}.services" mergedDns) // {
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
  dnsContracts =
    if forwarders == [ ] then
      dns
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
        routeContracts = listOrEmpty (dns.routeContracts or null) ++ builtins.map routeContractForForwarder forwarders;
        policyMatrix = listOrEmpty (dns.policyMatrix or null) ++ builtins.map routeContractForForwarder forwarders;
      };
in
if (targetWithDns.role or null) != "access" || forwarders == [ ] || dns == { } then
  targetWithDns
else
  addForwarderRoutes
    (targetWithDns
      // {
      services = (attrsOrEmpty (target.services or null)) // { dns = dnsContracts; };
    })
    forwarders
