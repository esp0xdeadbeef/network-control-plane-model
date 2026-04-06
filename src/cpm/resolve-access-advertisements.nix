{ helpers }:

{ sitePath, siteAttrs, runtimeTargets, realizationIndex }:

let
  inherit (helpers)
    hasAttr
    requireAttrs
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

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

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

  buildExplicitDHCP4Entry = targetDef: targetPath: target: interfaceName: entry:
    let
      entryPath = "${targetDef.nodePath}.advertisements.dhcp4.${interfaceName}";
      attrs = requireAttrs entryPath entry;
      enabled = boolOr true (attrs.enabled or null);
      runtimeInterface = getRuntimeTargetInterface targetPath target interfaceName;
      pool =
        if enabled then
          requireAttrs "${entryPath}.pool" (attrs.pool or null)
        else
          { };
    in
    if !enabled then
      {
        interface = interfaceName;
        bindInterface =
          requireString
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.runtimeIfName"
            (runtimeInterface.runtimeIfName or null);
        enabled = false;
      }
    else
      {
        interface = interfaceName;
        bindInterface =
          requireString
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.runtimeIfName"
            (runtimeInterface.runtimeIfName or null);
        tenant =
          (attrsOrEmpty (runtimeInterface.backingRef or null)).name or null;
        enabled = true;
        id = requireString "${entryPath}.id" (attrs.id or null);
        subnet = requireString "${entryPath}.subnet" (attrs.subnet or null);
        pool = {
          start = requireString "${entryPath}.pool.start" (pool.start or null);
          end = requireString "${entryPath}.pool.end" (pool.end or null);
        };
        router = requireString "${entryPath}.router" (attrs.router or null);
        dnsServers = requireStringList "${entryPath}.dnsServers" (attrs.dnsServers or null);
        domain = requireString "${entryPath}.domain" (attrs.domain or null);
      };

  buildExplicitIPv6RaEntry = targetDef: targetPath: target: interfaceName: entry:
    let
      entryPath = "${targetDef.nodePath}.advertisements.ipv6Ra.${interfaceName}";
      attrs = requireAttrs entryPath entry;
      enabled = boolOr true (attrs.enabled or null);
      runtimeInterface = getRuntimeTargetInterface targetPath target interfaceName;
    in
    if !enabled then
      {
        interface = interfaceName;
        bindInterface =
          requireString
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.runtimeIfName"
            (runtimeInterface.runtimeIfName or null);
        enabled = false;
      }
    else
      {
        interface = interfaceName;
        bindInterface =
          requireString
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.runtimeIfName"
            (runtimeInterface.runtimeIfName or null);
        tenant =
          (attrsOrEmpty (runtimeInterface.backingRef or null)).name or null;
        enabled = true;
        prefixes = requireStringList "${entryPath}.prefixes" (attrs.prefixes or null);
        rdnss = requireStringList "${entryPath}.rdnss" (attrs.rdnss or null);
        dnssl = requireStringList "${entryPath}.dnssl" (attrs.dnssl or null);
      };

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
