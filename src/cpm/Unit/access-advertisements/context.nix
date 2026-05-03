{
  helpers,
  sitePath,
  siteAttrs,
  routedPrefixesByTenant,
  advertisementHelpers,
}:

let
  inherit (helpers) hasAttr requireAttrs requireList requireString sortedNames;
  inherit (advertisementHelpers) failForwarding failInventory stripMask;

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
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
    in
    requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);

  getRuntimeTargetInterface = targetPath: target: interfaceName:
    let
      interfaces = getRuntimeTargetInterfaces targetPath target;
    in
    if hasAttr interfaceName interfaces then
      requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}" interfaces.${interfaceName}
    else
      failInventory
        "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
        "missing realized tenant interface '${interfaceName}' required for explicit access advertisements";

  validateNoUnexpectedInterfaces = inventoryPath: tenantInterfaceNames: entries:
    let
      tenantInterfaceSet =
        builtins.listToAttrs (builtins.map (interfaceName: {
          name = interfaceName;
          value = true;
        }) tenantInterfaceNames);
    in
    builtins.deepSeq
      (builtins.map
        (interfaceName:
          if hasAttr interfaceName tenantInterfaceSet then
            true
          else
            failInventory "${inventoryPath}.${interfaceName}" "references unknown tenant interface '${interfaceName}'")
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

  resolveTenantAdvertisementContext = targetPath: target: interfaceName:
    let
      runtimeInterface = getRuntimeTargetInterface targetPath target interfaceName;
      backingRef = advertisementHelpers.attrsOrEmpty (runtimeInterface.backingRef or null);
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
      tenantRa6Prefixes = tenantDefinition.ra6Prefixes or [ ];
      tenantRoutedPrefixes = routedPrefixesByTenant.${tenantName} or [ ];
    };

in
{
  inherit
    getRuntimeTargetInterfaces
    requireCoverage
    resolveTenantAdvertisementContext
    validateNoUnexpectedInterfaces
    ;
}
