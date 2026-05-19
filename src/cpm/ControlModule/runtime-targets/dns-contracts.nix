{
  lib,
  helpers,
  common,
  policyDerivedDnsAllowedClassesForListeners,
  policyDerivedDnsForwardersForListeners,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  dnsService = import ../../Unit/runtime-services/dns.nix {
    inherit lib helpers;
    inherit (common) failInventory;
  };
  inherit (dnsService) normalizeDnsService;

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
  }
