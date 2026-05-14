{
  lib,
  helpers,
  common,
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
