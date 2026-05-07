{
  lib,
  helpers,
  common,
  ipam,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  p2pPeers = import ../route-augmentation/p2p-peers.nix { inherit lib; };
  dnsService = import ../../Unit/runtime-services/dns.nix {
    inherit lib helpers;
    inherit (common) failInventory;
  };
  inherit (dnsService) normalizeDnsService;

  familyOf = value:
    if !builtins.isString value then
      null
    else if lib.network.ipv6.isValidIpStr value then
      6
    else if ipam.parseIPv4 value != null then
      4
    else
      null;
  routePresent = routes: dst:
    builtins.any (route: (route.dst or null) == dst) routes;

  routeForForwarder = family: iface: forwarder:
    let
      peer = p2pPeers.peerForInterface family iface;
    in
    if peer == null then
      null
    else
      {
        dst = forwarder;
        proto = "dns-service";
        intent = {
          kind = "dns-forwarder";
          source = "dns-service";
        };
      }
      // (if family == 4 then { via4 = peer; } else { via6 = peer; });

  addForwarderRoutes = iface: forwarders:
    let
      routes = attrsOrEmpty (iface.routes or null);
      forwarders4 = builtins.filter (forwarder: familyOf forwarder == 4) forwarders;
      forwarders6 = builtins.filter (forwarder: familyOf forwarder == 6) forwarders;
      appendMissing = family: existing: forwarder:
        let route = routeForForwarder family iface forwarder;
        in if route == null || routePresent existing forwarder then existing else existing ++ [ route ];
    in
    iface
    // {
      routes = routes // {
        ipv4 = builtins.foldl' (appendMissing 4) (listOrEmpty (routes.ipv4 or null)) forwarders4;
        ipv6 = builtins.foldl' (appendMissing 6) (listOrEmpty (routes.ipv6 or null)) forwarders6;
      };
    };

  routeContractForForwarder = forwarder: {
    dst = forwarder;
    source = "dns-service";
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

  synthesizeRouterSelfDns = target:
    let
      advertisements = attrsOrEmpty (target.advertisements or null);
      listeners = advertisedDnsListeners advertisements;
      sources = advertisedDnsSources advertisements;
      localContracts = builtins.map routeContractForListener listeners;
    in
    if (target.role or null) != "access" || listeners == [ ] || attrsOrEmpty (target.services.dns or null) != { } then
      target
    else
      target
      // {
        services = (attrsOrEmpty (target.services or null)) // {
          dns = normalizeDnsService "runtimeTargets.${target.logicalNode.name or "access"}.services" {
            listen = listeners;
            allowFrom = sources;
            routeContracts = localContracts;
            policyMatrix = localContracts;
          };
        };
      };
in
target:
let
  targetWithDns = synthesizeRouterSelfDns target;
  dns = attrsOrEmpty (targetWithDns.services.dns or null);
  forwarders = listOrEmpty (dns.forwarders or null);
  effective = attrsOrEmpty (targetWithDns.effectiveRuntimeRealization or null);
  interfaces = attrsOrEmpty (effective.interfaces or null);
  updatedInterfaces =
    builtins.mapAttrs
      (_: iface:
        if (iface.sourceKind or null) == "p2p" then addForwarderRoutes iface forwarders else iface)
      interfaces;
  dnsContracts =
    if forwarders == [ ] then
      dns
    else
      dns
      // {
        routeContracts = listOrEmpty (dns.routeContracts or null) ++ builtins.map routeContractForForwarder forwarders;
        policyMatrix = listOrEmpty (dns.policyMatrix or null) ++ builtins.map routeContractForForwarder forwarders;
      };
in
if (targetWithDns.role or null) != "access" || forwarders == [ ] || dns == { } then
  targetWithDns
else
  targetWithDns
  // {
    services = (attrsOrEmpty (target.services or null)) // { dns = dnsContracts; };
    effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; };
  }
