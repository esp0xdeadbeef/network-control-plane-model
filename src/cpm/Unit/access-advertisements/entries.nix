{ helpers
, sitePath
, ipam
, advertisementHelpers
, advertisementContext
,
}:

let
  inherit (helpers) requireAttrs requireList requireString requireStringList;
  inherit (advertisementHelpers)
    boolOr
    failForwarding
    failInventory
    isNonEmptyString
    defaultDHCP4Pool
    resolveAdvertisedIPv4Targets
    resolveAdvertisedIPv6Targets
    validateOptionalResolvedIPv4Match
    validateOptionalStringListMatch
    validateOptionalStringMatch
    ;
  inherit (advertisementContext) resolveTenantAdvertisementContext;

  requireInt = path: value:
    if builtins.isInt value then value else failInventory path "must be an integer";

  normalizeMac = path: value:
    let
      mac = requireString path value;
      normalized = builtins.replaceStrings [ "-" ] [ ":" ] mac;
    in
    if builtins.match "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" normalized != null then
      normalized
    else
      failInventory path "must be a MAC address";

  duplicate = values:
    let
      names = builtins.attrNames (builtins.listToAttrs (map (value: { name = value; value = true; }) values));
    in
    builtins.length names != builtins.length values;

  ensureUniqueValues = path: label: values:
    if duplicate values then failInventory path "duplicate ${label} in the same network" else true;

  reservationHostOffset = reservationPath: attrs: familyName:
    let
      familyAttrs = requireAttrs "${reservationPath}.${familyName}" (attrs.${familyName} or null);
    in
    requireInt "${reservationPath}.${familyName}.hostOffset" (familyAttrs.hostOffset or null);

  resolveReservations =
    family: familyName: perNodePrefixLength: entryPath: interfaceName: subnet: rawReservations:
    let
      reservations = if rawReservations == null then [ ] else requireList "${entryPath}.reservations" rawReservations;
      rendered =
        builtins.genList
          (idx:
            let
              reservationPath = "${entryPath}.reservations[${toString idx}]";
              attrs = requireAttrs reservationPath (builtins.elemAt reservations idx);
              mac = normalizeMac "${reservationPath}.mac" (attrs.mac or null);
              hostOffset = reservationHostOffset reservationPath attrs familyName;
              cidr = ipam.allocOne {
                inherit family perNodePrefixLength;
                prefix = subnet;
                offset = hostOffset;
              };
              address = builtins.elemAt (builtins.split "/" cidr) 0;
            in
            {
              id =
                if isNonEmptyString (attrs.id or null) then
                  attrs.id
                else if isNonEmptyString (attrs.name or null) then
                  attrs.name
                else
                  mac;
              inherit mac hostOffset address cidr;
              source = "inventory-realization";
            }
            // (if isNonEmptyString (attrs.hostname or null) then { hostname = attrs.hostname; } else { })
            // (if isNonEmptyString (attrs.duid or null) then { duid = attrs.duid; } else { }))
          (builtins.length reservations);
      _uniqueMacs = ensureUniqueValues "${entryPath}.reservations" "MAC address" (map (reservation: reservation.mac) rendered);
      _uniqueOffsets =
        ensureUniqueValues
          "${entryPath}.reservations"
          "${familyName}.hostOffset"
          (map (reservation: toString reservation.hostOffset) rendered);
    in
    builtins.seq _uniqueMacs (builtins.seq _uniqueOffsets rendered);

  dhcpv6 = import ./dhcpv6.nix {
    inherit helpers sitePath ipam advertisementHelpers advertisementContext resolveReservations;
  };

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
    } else { }))));

  buildExplicitIPv6RaEntry = targetDef: targetPath: target: interfaceName: entry:
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
      inherit managed otherConfig onLink autonomous;
    } else { })
    // (if routedIpv6Prefixes != [ ] then {
      routedPrefixes = routedIpv6Prefixes;
      delegatedPrefix = builtins.head routedIpv6Prefixes;
    } else { }));

in
{
  inherit
    buildExplicitDHCP4Entry
    buildExplicitIPv6RaEntry
    ;
  inherit (dhcpv6) buildExplicitDHCPv6Entry;
}
