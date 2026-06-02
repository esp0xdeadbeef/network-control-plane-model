{ helpers
, sitePath
, advertisementHelpers
, advertisementContext
, resolveReservations
,
}:

let
  inherit (helpers) requireAttrs requireString;
  inherit (advertisementHelpers)
    boolOr
    failForwarding
    isNonEmptyString
    defaultDHCP4Pool
    resolveAdvertisedIPv4Targets
    validateOptionalResolvedIPv4Match
    validateOptionalStringMatch
    ;
  inherit (advertisementContext) resolveTenantAdvertisementContext;
in
targetDef: targetPath: target: interfaceName: entry:
let
  entryPath = "${targetDef.nodePath}.advertisements.dhcp4.${interfaceName}";
  attrs = requireAttrs entryPath entry;
  enabled = boolOr true (attrs.enabled or null);
  tenantContext = resolveTenantAdvertisementContext targetPath target interfaceName;
  routerAddress =
    if enabled && !isNonEmptyString tenantContext.interfaceAddr4 then
      failForwarding
        "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.addr4"
        "tenant interface requires explicit ipv4 address for DHCP advertisement derivation"
    else
      tenantContext.interfaceAddr4;
  subnet =
    if enabled && !isNonEmptyString tenantContext.tenantIPv4Prefix then
      failForwarding
        "${sitePath}.domains.tenants"
        "tenant '${tenantContext.tenantName}' requires explicit ipv4 prefix for DHCP advertisement derivation"
    else
      tenantContext.tenantIPv4Prefix;
  _idMatch =
    validateOptionalStringMatch entryPath "id" (attrs.id or null) tenantContext.tenantName
      "must match tenant identity '${tenantContext.tenantName}' derived from the forwarding model";
  _subnetMatch =
    validateOptionalStringMatch entryPath "subnet" (attrs.subnet or null) subnet
      "must match tenant IPv4 prefix '${subnet}' derived from the forwarding model";
  _routerMatch =
    validateOptionalResolvedIPv4Match entryPath "router" (attrs.router or null) routerAddress
      "must match realized tenant interface address '${routerAddress}' or use 'router-self'";
  pool =
    if !enabled then
      { }
    else if builtins.isAttrs (attrs.pool or null) then
      requireAttrs "${entryPath}.pool" attrs.pool
    else
      defaultDHCP4Pool entryPath subnet;
  dnsServers =
    if enabled then resolveAdvertisedIPv4Targets entryPath "dnsServers" routerAddress (attrs.dnsServers or null) else [ ];
  reservations =
    if enabled then
      resolveReservations 4 "ipv4" 32 entryPath interfaceName subnet (attrs.reservations or null)
    else
      [ ];
  bindInterface =
    requireString
      "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.runtimeIfName"
      (tenantContext.runtimeInterface.runtimeIfName or null);
  routerInterface =
    {
      logicalInterface = interfaceName;
      bindInterface = bindInterface;
      tenant = tenantContext.tenantName;
      address4 = routerAddress;
      subnet4 = subnet;
    }
    // (if isNonEmptyString tenantContext.interfaceAddr6 then { address6 = tenantContext.interfaceAddr6; } else { })
    // (if isNonEmptyString tenantContext.tenantIPv6Prefix then { subnet6 = tenantContext.tenantIPv6Prefix; } else { });
in
builtins.seq _idMatch (builtins.seq _subnetMatch (builtins.seq _routerMatch ({
  interface = interfaceName;
  bindInterface = bindInterface;
  tenant = tenantContext.tenantName;
  router = routerAddress;
  routerAddress = routerAddress;
  routerInterfaceAddress = routerAddress;
  authoritativeRouterAddress = routerAddress;
  enabled = enabled;
  inherit routerInterface;
}
// (if enabled then {
  id = tenantContext.tenantName;
  subnet = subnet;
  pool = {
    start = requireString "${entryPath}.pool.start" (pool.start or null);
    end = requireString "${entryPath}.pool.end" (pool.end or null);
  };
  inherit reservations;
  dnsServers = dnsServers;
  domain = requireString "${entryPath}.domain" (attrs.domain or null);
} else { }))))
