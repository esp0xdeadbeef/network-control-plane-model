{ helpers
, sitePath
, advertisementHelpers
, advertisementContext
,
}:

let
  inherit (helpers) requireAttrs requireString requireStringList;
  inherit (advertisementHelpers)
    boolOr
    failForwarding
    isNonEmptyString
    resolveAdvertisedIPv6Targets
    validateOptionalStringListMatch
    ;
  inherit (advertisementContext) resolveTenantAdvertisementContext;
in
targetDef: targetPath: target: interfaceName: entry:
let
  entryPath = "${targetDef.nodePath}.advertisements.ipv6Ra.${interfaceName}";
  attrs = requireAttrs entryPath entry;
  enabled = boolOr true (attrs.enabled or null);
  tenantContext = resolveTenantAdvertisementContext targetPath target interfaceName;
  routerAddress =
    if enabled && !isNonEmptyString tenantContext.interfaceAddr6 then
      failForwarding
        "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.addr6"
        "tenant interface requires explicit ipv6 address for router advertisement derivation"
    else
      tenantContext.interfaceAddr6;
  prefixes =
    if !enabled then
      [ ]
    else if tenantContext.tenantRa6Prefixes != [ ] then
      tenantContext.tenantRa6Prefixes
    else if isNonEmptyString tenantContext.tenantIPv6Prefix then
      [ tenantContext.tenantIPv6Prefix ]
    else
      failForwarding
        "${sitePath}.domains.tenants"
        "tenant '${tenantContext.tenantName}' requires explicit ipv6 prefix for router advertisement derivation";
  routedIpv6Prefixes =
    if enabled then builtins.filter (prefix: (prefix.family or null) == "ipv6") tenantContext.tenantRoutedPrefixes else [ ];
  _prefixMatch =
    validateOptionalStringListMatch
      entryPath
      "prefixes"
      (attrs.prefixes or null)
      prefixes
      "must match tenant IPv6 advertisement prefixes derived from the forwarding model";
  rdnss = if enabled then resolveAdvertisedIPv6Targets entryPath "rdnss" routerAddress (attrs.rdnss or null) else [ ];
  moreSpecificRoutes =
    if enabled then
      builtins.filter builtins.isString (builtins.map (r: r.dst or null) tenantContext.internalReachabilityRoutes6)
    else
      [ ];
  defaultRoute = if enabled then tenantContext.hasIPv6DefaultRoute else false;
  managed = boolOr false (attrs.managed or null);
  otherConfig = boolOr false (attrs.otherConfig or null);
  onLink = boolOr true (attrs.onLink or null);
  autonomous = boolOr true (attrs.autonomous or null);
  bindInterface =
    requireString
      "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.runtimeIfName"
      (tenantContext.runtimeInterface.runtimeIfName or null);
  routerInterface =
    {
      logicalInterface = interfaceName;
      bindInterface = bindInterface;
      tenant = tenantContext.tenantName;
      address6 = routerAddress;
      subnet6 = tenantContext.tenantIPv6Prefix;
      advertisedPrefixes6 = prefixes;
    }
    // (if isNonEmptyString tenantContext.interfaceAddr4 then { address4 = tenantContext.interfaceAddr4; } else { })
    // (if isNonEmptyString tenantContext.tenantIPv4Prefix then { subnet4 = tenantContext.tenantIPv4Prefix; } else { });
in
builtins.seq _prefixMatch ({
  interface = interfaceName;
  bindInterface = bindInterface;
  tenant = tenantContext.tenantName;
  routerAddress = routerAddress;
  routerInterfaceAddress = routerAddress;
  authoritativeRouterAddress = routerAddress;
  enabled = enabled;
  inherit routerInterface;
}
// (if enabled then {
  prefixes = prefixes;
  rdnss = rdnss;
  dnssl = requireStringList "${entryPath}.dnssl" (attrs.dnssl or null);
  inherit managed otherConfig onLink autonomous moreSpecificRoutes defaultRoute;
} else { })
// (if routedIpv6Prefixes != [ ] then {
  routedPrefixes = routedIpv6Prefixes;
  delegatedPrefix = builtins.head routedIpv6Prefixes;
} else { }))
