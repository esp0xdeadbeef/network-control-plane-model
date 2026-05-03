{
  helpers,
  sitePath,
  advertisementHelpers,
  advertisementContext,
}:

let
  inherit (helpers) requireAttrs requireString requireStringList;
  inherit (advertisementHelpers)
    boolOr
    failForwarding
    isNonEmptyString
    resolveAdvertisedIPv4Targets
    resolveAdvertisedIPv6Targets
    validateOptionalResolvedIPv4Match
    validateOptionalStringListMatch
    validateOptionalStringMatch
    ;
  inherit (advertisementContext) resolveTenantAdvertisementContext;

  buildExplicitDHCP4Entry = targetDef: targetPath: target: interfaceName: entry:
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
      pool = if enabled then requireAttrs "${entryPath}.pool" (attrs.pool or null) else { };
      dnsServers =
        if enabled then resolveAdvertisedIPv4Targets entryPath "dnsServers" routerAddress (attrs.dnsServers or null) else [ ];
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
      dnsServers = dnsServers;
      domain = requireString "${entryPath}.domain" (attrs.domain or null);
    } else { }))));

  buildExplicitIPv6RaEntry = targetDef: targetPath: target: interfaceName: entry: externalValidation:
    let
      entryPath = "${targetDef.nodePath}.advertisements.ipv6Ra.${interfaceName}";
      attrs = requireAttrs entryPath entry;
      enabled = boolOr true (attrs.enabled or null);
      extValid = if builtins.isAttrs externalValidation then externalValidation else { };
      hasDelegatedPrefixValidation =
        (extValid.delegatedIPv6Prefix or false) == true
        || (extValid.delegatedIPv6Prefixes or false) == true
        || (extValid.delegatedPrefixSecretPath or "" != "");
      tenantContext = resolveTenantAdvertisementContext targetPath target interfaceName;
      routerAddress =
        if enabled && !isNonEmptyString tenantContext.interfaceAddr6 then
          failForwarding
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.addr6"
            "tenant interface requires explicit ipv6 address for router advertisement derivation"
        else
          tenantContext.interfaceAddr6;
      prefixes =
        if !enabled || hasDelegatedPrefixValidation then
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
        if hasDelegatedPrefixValidation then
          true
        else
          validateOptionalStringListMatch
            entryPath
            "prefixes"
            (attrs.prefixes or null)
            prefixes
            "must match tenant IPv6 advertisement prefixes derived from the forwarding model";
      rdnss = if enabled then resolveAdvertisedIPv6Targets entryPath "rdnss" routerAddress (attrs.rdnss or null) else [ ];
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
    } else { })
    // (if routedIpv6Prefixes != [ ] then {
      routedPrefixes = routedIpv6Prefixes;
      delegatedPrefix = builtins.head routedIpv6Prefixes;
    } else { })
    // (if hasDelegatedPrefixValidation then { externalValidation = extValid; } else { }));

in
{
  inherit
    buildExplicitDHCP4Entry
    buildExplicitIPv6RaEntry
    ;
}
