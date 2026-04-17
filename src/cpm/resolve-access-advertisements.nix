{ helpers }:

{ sitePath, siteAttrs, runtimeTargets, realizationIndex, endpointInventoryIndex }:

let
  inherit (helpers)
    hasAttr
    requireAttrs
    requireList
    requireString
    requireStringList
    sortedNames
    ;

  attrsOrEmpty = value:
    if builtins.isAttrs value then
      value
    else
      { };

  boolOr = fallback: value:
    if builtins.isBool value then
      value
    else
      fallback;

  isNonEmptyString = value:
    builtins.isString value && value != "";

  isIPv4Literal = value:
    builtins.isString value
    && builtins.match "([0-9]{1,3}\\.){3}[0-9]{1,3}" value != null;

  isIPv6Literal = value:
    builtins.isString value
    && builtins.match ".*:.*" value != null
    && builtins.match "[0-9A-Fa-f:.]+" value != null;

  stripMask = addr:
    if isNonEmptyString addr then
      builtins.elemAt (builtins.split "/" addr) 0
    else
      null;

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  failForwarding = path: message:
    throw "forwarding-model update required: ${path}: ${message}";

  siteDomains = requireAttrs "${sitePath}.domains" (siteAttrs.domains or null);

  tenantDefinitions =
    builtins.listToAttrs (
      builtins.map
        (tenant:
          let
            tenantAttrs = requireAttrs "${sitePath}.domains.tenants[*]" tenant;
            tenantName = requireString "${sitePath}.domains.tenants[*].name" (tenantAttrs.name or null);
          in
          {
            name = tenantName;
            value = tenantAttrs;
          })
        (requireList "${sitePath}.domains.tenants" (siteDomains.tenants or null))
    );

  getRuntimeTargetInterfaces = targetPath: target:
    let
      effective =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization"
          (target.effectiveRuntimeRealization or null);
    in
    requireAttrs
      "${targetPath}.effectiveRuntimeRealization.interfaces"
      (effective.interfaces or null);

  getRuntimeTargetInterface = targetPath: target: interfaceName:
    let
      interfaces = getRuntimeTargetInterfaces targetPath target;
    in
    if hasAttr interfaceName interfaces then
      requireAttrs
        "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
        interfaces.${interfaceName}
    else
      failInventory
        "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
        "missing realized tenant interface '${interfaceName}' required for explicit access advertisements";

  validateNoUnexpectedInterfaces = inventoryPath: tenantInterfaceNames: entries:
    let
      tenantInterfaceSet =
        builtins.listToAttrs (
          builtins.map
            (interfaceName: {
              name = interfaceName;
              value = true;
            })
            tenantInterfaceNames
        );
    in
    builtins.deepSeq
      (builtins.map
        (interfaceName:
          if hasAttr interfaceName tenantInterfaceSet then
            true
          else
            failInventory
              "${inventoryPath}.${interfaceName}"
              "references unknown tenant interface '${interfaceName}'")
        (sortedNames entries))
      true;

  requireCoverage = inventoryPath: tenantInterfaceNames: entries:
    builtins.deepSeq
      (builtins.map
        (interfaceName:
          if hasAttr interfaceName entries then
            true
          else
            failInventory
              "${inventoryPath}.${interfaceName}"
              "missing explicit advertisement realization for tenant interface '${interfaceName}'")
        tenantInterfaceNames)
      true;

  validateOptionalStringMatch = entryPath: fieldName: value: expected: message:
    if value == null then
      true
    else
      let
        rendered = requireString "${entryPath}.${fieldName}" value;
      in
      if rendered == expected then
        true
      else
        failInventory "${entryPath}.${fieldName}" message;

  validateOptionalResolvedIPv4Match = entryPath: fieldName: value: expected: message:
    if value == null then
      true
    else
      let
        rendered = requireString "${entryPath}.${fieldName}" value;
        resolved =
          if rendered == "router-self" then
            expected
          else
            rendered;
      in
      if resolved == expected then
        true
      else
        failInventory "${entryPath}.${fieldName}" message;

  validateOptionalStringListMatch = entryPath: fieldName: value: expected: message:
    if value == null then
      true
    else
      let
        rendered = requireStringList "${entryPath}.${fieldName}" value;
      in
      if rendered == expected then
        true
      else
        failInventory "${entryPath}.${fieldName}" message;

  resolveAdvertisedIPv4Target = entryPath: fieldName: routerAddress: index: rawValue:
    let
      address =
        requireString
          "${entryPath}.${fieldName}[${toString index}]"
          rawValue;
    in
    if address == "router-self" then
      routerAddress
    else if address == routerAddress || hasAttr address endpointInventoryIndex.byIPv4 || isIPv4Literal address then
      address
    else
      failInventory
        "${entryPath}.${fieldName}[${toString index}]"
        "must resolve to an explicit router interface address, 'router-self', inventory.endpoints IPv4 address, or explicit IPv4 literal; '${address}' is not explicitly defined";

  resolveAdvertisedIPv6Target = entryPath: fieldName: routerAddress: index: rawValue:
    let
      address =
        requireString
          "${entryPath}.${fieldName}[${toString index}]"
          rawValue;
    in
    if address == "router-self" then
      routerAddress
    else if address == routerAddress || hasAttr address endpointInventoryIndex.byIPv6 || isIPv6Literal address then
      address
    else
      failInventory
        "${entryPath}.${fieldName}[${toString index}]"
        "must resolve to an explicit router interface address, 'router-self', inventory.endpoints IPv6 address, or explicit IPv6 literal; '${address}' is not explicitly defined";

  resolveAdvertisedIPv4Targets = entryPath: fieldName: routerAddress: rawValue:
    let
      configured =
        if rawValue == null then
          [ "router-self" ]
        else
          requireStringList "${entryPath}.${fieldName}" rawValue;
    in
    builtins.genList
      (idx:
        resolveAdvertisedIPv4Target
          entryPath
          fieldName
          routerAddress
          idx
          (builtins.elemAt configured idx))
      (builtins.length configured);

  resolveAdvertisedIPv6Targets = entryPath: fieldName: routerAddress: rawValue:
    let
      configured =
        if rawValue == null then
          [ "router-self" ]
        else
          requireStringList "${entryPath}.${fieldName}" rawValue;
    in
    builtins.genList
      (idx:
        resolveAdvertisedIPv6Target
          entryPath
          fieldName
          routerAddress
          idx
          (builtins.elemAt configured idx))
      (builtins.length configured);

  resolveTenantAdvertisementContext = targetPath: target: interfaceName:
    let
      runtimeInterface = getRuntimeTargetInterface targetPath target interfaceName;
      backingRef = attrsOrEmpty (runtimeInterface.backingRef or null);
      tenantName =
        if (backingRef.kind or null) == "attachment" then
          requireString
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.backingRef.name"
            (backingRef.name or null)
        else
          failForwarding
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.backingRef"
            "access advertisements require an explicit tenant-backed interface realization";

      tenantDefinition =
        if hasAttr tenantName tenantDefinitions then
          tenantDefinitions.${tenantName}
        else
          failForwarding
            "${sitePath}.domains.tenants"
            "tenant '${tenantName}' requires an explicit site.domains.tenants entry for advertisement derivation";
    in
    {
      inherit runtimeInterface tenantName tenantDefinition;
      interfaceAddr4 = stripMask (runtimeInterface.addr4 or null);
      interfaceAddr6 = stripMask (runtimeInterface.addr6 or null);
      tenantIPv4Prefix = tenantDefinition.ipv4 or null;
      tenantIPv6Prefix = tenantDefinition.ipv6 or null;
    };

  buildExplicitDHCP4Entry = targetDef: targetPath: target: interfaceName: entry:
    let
      entryPath = "${targetDef.nodePath}.advertisements.dhcp4.${interfaceName}";
      attrs = requireAttrs entryPath entry;
      enabled = boolOr true (attrs.enabled or null);

      tenantContext =
        resolveTenantAdvertisementContext targetPath target interfaceName;

      routerAddress =
        if enabled then
          if isNonEmptyString tenantContext.interfaceAddr4 then
            tenantContext.interfaceAddr4
          else
            failForwarding
              "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.addr4"
              "tenant interface requires explicit ipv4 address for DHCP advertisement derivation"
        else
          tenantContext.interfaceAddr4;

      subnet =
        if enabled then
          if isNonEmptyString tenantContext.tenantIPv4Prefix then
            tenantContext.tenantIPv4Prefix
          else
            failForwarding
              "${sitePath}.domains.tenants"
              "tenant '${tenantContext.tenantName}' requires explicit ipv4 prefix for DHCP advertisement derivation"
        else
          tenantContext.tenantIPv4Prefix;

      _idMatch =
        validateOptionalStringMatch
          entryPath
          "id"
          (attrs.id or null)
          tenantContext.tenantName
          "must match tenant identity '${tenantContext.tenantName}' derived from the forwarding model";

      _subnetMatch =
        validateOptionalStringMatch
          entryPath
          "subnet"
          (attrs.subnet or null)
          subnet
          "must match tenant IPv4 prefix '${subnet}' derived from the forwarding model";

      _routerMatch =
        validateOptionalResolvedIPv4Match
          entryPath
          "router"
          (attrs.router or null)
          routerAddress
          "must match realized tenant interface address '${routerAddress}' or use 'router-self'";

      pool =
        if enabled then
          requireAttrs "${entryPath}.pool" (attrs.pool or null)
        else
          { };

      dnsServers =
        if enabled then
          resolveAdvertisedIPv4Targets
            entryPath
            "dnsServers"
            routerAddress
            (attrs.dnsServers or null)
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
        // (
          if isNonEmptyString tenantContext.interfaceAddr6 then
            {
              address6 = tenantContext.interfaceAddr6;
            }
          else
            { }
        )
        // (
          if isNonEmptyString tenantContext.tenantIPv6Prefix then
            {
              subnet6 = tenantContext.tenantIPv6Prefix;
            }
          else
            { }
        );
    in
    builtins.seq
      _idMatch
      (builtins.seq
        _subnetMatch
        (builtins.seq
          _routerMatch
          ({
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
          // (
            if !enabled then
              { }
            else
              {
                id = tenantContext.tenantName;
                subnet = subnet;
                pool = {
                  start = requireString "${entryPath}.pool.start" (pool.start or null);
                  end = requireString "${entryPath}.pool.end" (pool.end or null);
                };
                dnsServers = dnsServers;
                domain = requireString "${entryPath}.domain" (attrs.domain or null);
              }
          ))));

  buildExplicitIPv6RaEntry = targetDef: targetPath: target: interfaceName: entry:
    let
      entryPath = "${targetDef.nodePath}.advertisements.ipv6Ra.${interfaceName}";
      attrs = requireAttrs entryPath entry;
      enabled = boolOr true (attrs.enabled or null);

      tenantContext =
        resolveTenantAdvertisementContext targetPath target interfaceName;

      routerAddress =
        if enabled then
          if isNonEmptyString tenantContext.interfaceAddr6 then
            tenantContext.interfaceAddr6
          else
            failForwarding
              "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.addr6"
              "tenant interface requires explicit ipv6 address for router advertisement derivation"
        else
          tenantContext.interfaceAddr6;

      prefixes =
        if enabled then
          if isNonEmptyString tenantContext.tenantIPv6Prefix then
            [ tenantContext.tenantIPv6Prefix ]
          else
            failForwarding
              "${sitePath}.domains.tenants"
              "tenant '${tenantContext.tenantName}' requires explicit ipv6 prefix for router advertisement derivation"
        else
          [ ];

      _prefixMatch =
        validateOptionalStringListMatch
          entryPath
          "prefixes"
          (attrs.prefixes or null)
          prefixes
          "must match tenant IPv6 prefix '${tenantContext.tenantIPv6Prefix}' derived from the forwarding model";

      rdnss =
        if enabled then
          resolveAdvertisedIPv6Targets
            entryPath
            "rdnss"
            routerAddress
            (attrs.rdnss or null)
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
          address6 = routerAddress;
          subnet6 = tenantContext.tenantIPv6Prefix;
        }
        // (
          if isNonEmptyString tenantContext.interfaceAddr4 then
            {
              address4 = tenantContext.interfaceAddr4;
            }
          else
            { }
        )
        // (
          if isNonEmptyString tenantContext.tenantIPv4Prefix then
            {
              subnet4 = tenantContext.tenantIPv4Prefix;
            }
          else
            { }
        );
    in
    builtins.seq
      _prefixMatch
      ({
        interface = interfaceName;
        bindInterface = bindInterface;
        tenant = tenantContext.tenantName;
        routerAddress = routerAddress;
        routerInterfaceAddress = routerAddress;
        authoritativeRouterAddress = routerAddress;
        enabled = enabled;
        inherit routerInterface;
      }
      // (
        if !enabled then
          { }
        else
          {
            prefixes = prefixes;
            rdnss = rdnss;
            dnssl = requireStringList "${entryPath}.dnssl" (attrs.dnssl or null);
          }
      ));

  buildAccessTargetEntry = targetName:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      target = requireAttrs targetPath runtimeTargets.${targetName};
      role = target.role or null;
    in
    if role != "access" then
      null
    else
      let
        placement = requireAttrs "${targetPath}.placement" (target.placement or null);
        placementKind = placement.kind or null;
      in
      if placementKind != "inventory-realization" then
        null
      else
        let
          targetId = requireString "${targetPath}.placement.target" (placement.target or null);

          targetDef =
            if hasAttr targetId realizationIndex.targetDefs then
              realizationIndex.targetDefs.${targetId}
            else
              failInventory
                "inventory.realization.nodes.${targetId}"
                "access runtime target '${targetId}' must be explicitly realized";

          inventoryNode = requireAttrs targetDef.nodePath targetDef.node;
          inventoryAdvertisements =
            if builtins.isAttrs (inventoryNode.advertisements or null) then
              requireAttrs "${targetDef.nodePath}.advertisements" inventoryNode.advertisements
            else
              failInventory
                "${targetDef.nodePath}.advertisements"
                "access runtime target '${targetId}' requires explicit advertisements realization";

          dhcp4Entries =
            requireAttrs
              "${targetDef.nodePath}.advertisements.dhcp4"
              (inventoryAdvertisements.dhcp4 or null);

          ipv6RaEntries =
            requireAttrs
              "${targetDef.nodePath}.advertisements.ipv6Ra"
              (inventoryAdvertisements.ipv6Ra or null);

          interfaces = getRuntimeTargetInterfaces targetPath target;

          tenantInterfaceNames =
            builtins.filter
              (interfaceName:
                let
                  iface =
                    requireAttrs
                      "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
                      interfaces.${interfaceName};
                in
                (iface.sourceKind or null) == "tenant")
              (sortedNames interfaces);

          _dhcp4Coverage =
            requireCoverage
              "${targetDef.nodePath}.advertisements.dhcp4"
              tenantInterfaceNames
              dhcp4Entries;

          _ipv6RaCoverage =
            requireCoverage
              "${targetDef.nodePath}.advertisements.ipv6Ra"
              tenantInterfaceNames
              ipv6RaEntries;

          _dhcp4NoUnexpected =
            validateNoUnexpectedInterfaces
              "${targetDef.nodePath}.advertisements.dhcp4"
              tenantInterfaceNames
              dhcp4Entries;

          _ipv6RaNoUnexpected =
            validateNoUnexpectedInterfaces
              "${targetDef.nodePath}.advertisements.ipv6Ra"
              tenantInterfaceNames
              ipv6RaEntries;

          value = {
            dhcp4 =
              builtins.map
                (interfaceName:
                  buildExplicitDHCP4Entry targetDef targetPath target interfaceName dhcp4Entries.${interfaceName})
                tenantInterfaceNames;
            ipv6Ra =
              builtins.map
                (interfaceName:
                  buildExplicitIPv6RaEntry targetDef targetPath target interfaceName ipv6RaEntries.${interfaceName})
                tenantInterfaceNames;
          };
        in
        builtins.seq
          _dhcp4Coverage
          (builtins.seq
            _ipv6RaCoverage
            (builtins.seq
              _dhcp4NoUnexpected
              (builtins.seq
                _ipv6RaNoUnexpected
                {
                  name = targetName;
                  inherit value;
                })));
in
builtins.listToAttrs (
  builtins.filter
    (entry: entry != null)
    (builtins.map
      buildAccessTargetEntry
      (sortedNames runtimeTargets))
)
