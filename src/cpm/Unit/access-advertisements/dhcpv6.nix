{ helpers
, sitePath
, ipam
, advertisementHelpers
, advertisementContext
, resolveReservationSource
, resolveReservations
,
}:

let
  inherit (helpers) requireAttrs requireString;
  inherit (advertisementHelpers)
    boolOr
    failForwarding
    failInventory
    isNonEmptyString
    resolveAdvertisedIPv6Targets
    validateOptionalResolvedIPv6Match
    validateOptionalStringMatch
    ;
  inherit (advertisementContext) resolveTenantAdvertisementContext;

  poolStringFrom = entryPath: value:
    if builtins.isString value then
      value
    else if builtins.isAttrs value then
      let
        start = requireString "${entryPath}.pool.start" (value.start or null);
        end = requireString "${entryPath}.pool.end" (value.end or null);
      in
      "${start} - ${end}"
    else
      failInventory "${entryPath}.pool" "explicit DHCPv6 advertisement requires a pool string or { start, end }";

  buildExplicitDHCPv6Entry = targetDef: targetPath: target: interfaceName: entry:
    let
      entryPath = "${targetDef.nodePath}.advertisements.dhcpv6.${interfaceName}";
      attrs = requireAttrs entryPath entry;
      enabled = boolOr true (attrs.enabled or null);
      tenantContext = resolveTenantAdvertisementContext targetPath target interfaceName;
      serverAddress =
        if enabled && !isNonEmptyString tenantContext.interfaceAddr6 then
          failForwarding
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.addr6"
            "tenant interface requires explicit ipv6 address for DHCPv6 advertisement derivation"
        else
          tenantContext.interfaceAddr6;
      subnet =
        if enabled && !isNonEmptyString tenantContext.tenantIPv6Prefix then
          failForwarding
            "${sitePath}.domains.tenants"
            "tenant '${tenantContext.tenantName}' requires explicit ipv6 prefix for DHCPv6 advertisement derivation"
        else
          tenantContext.tenantIPv6Prefix;
      _idMatch =
        validateOptionalStringMatch entryPath "id" (attrs.id or null) tenantContext.tenantName
          "must match tenant identity '${tenantContext.tenantName}' derived from the forwarding model";
      _subnetMatch =
        validateOptionalStringMatch entryPath "subnet" (attrs.subnet or null) subnet
          "must match tenant IPv6 prefix '${subnet}' derived from the forwarding model";
      _serverMatch =
        validateOptionalResolvedIPv6Match entryPath "serverAddress" (attrs.serverAddress or null) serverAddress
          "must match realized tenant interface IPv6 address '${serverAddress}' or use 'router-self'";
      pool = if enabled then poolStringFrom entryPath (attrs.pool or null) else "";
      dnsServers =
        if enabled then resolveAdvertisedIPv6Targets entryPath "dnsServers" serverAddress (attrs.dnsServers or null) else [ ];
      reservations =
        if enabled then
          resolveReservations 6 "ipv6" 128 entryPath interfaceName subnet (attrs.reservations or null)
        else
          [ ];
      reservationSource =
        if enabled then
          resolveReservationSource "ipv6" entryPath (attrs.reservationSource or null) (attrs.reservations or null)
        else
          null;
      leaseState =
        if enabled && attrs ? leaseState then
          let
            state = requireAttrs "${entryPath}.leaseState" attrs.leaseState;
          in
          {
            path = requireString "${entryPath}.leaseState.path" (state.path or null);
          }
        else
          null;
      bindInterface =
        requireString
          "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.runtimeIfName"
          (tenantContext.runtimeInterface.runtimeIfName or null);
      routerInterface =
        {
          logicalInterface = interfaceName;
          bindInterface = bindInterface;
          tenant = tenantContext.tenantName;
          address6 = serverAddress;
          subnet6 = subnet;
        }
        // (if isNonEmptyString tenantContext.interfaceAddr4 then { address4 = tenantContext.interfaceAddr4; } else { })
        // (if isNonEmptyString tenantContext.tenantIPv4Prefix then { subnet4 = tenantContext.tenantIPv4Prefix; } else { });
    in
    builtins.seq _idMatch (builtins.seq _subnetMatch (builtins.seq _serverMatch ({
      interface = interfaceName;
      bindInterface = bindInterface;
      tenant = tenantContext.tenantName;
      serverAddress = serverAddress;
      routerInterfaceAddress = serverAddress;
      authoritativeRouterAddress = serverAddress;
      enabled = enabled;
      inherit routerInterface;
    }
    // (if enabled then {
      id = tenantContext.tenantName;
      subnet = subnet;
      pool = pool;
      inherit reservations;
      dnsServers = dnsServers;
      domain = requireString "${entryPath}.domain" (attrs.domain or null);
    }
    // (if reservationSource != null then { inherit reservationSource; } else { })
    // (if leaseState != null then { inherit leaseState; } else { })
    else { }))));
in
{
  inherit buildExplicitDHCPv6Entry;
}
