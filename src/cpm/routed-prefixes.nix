{ helpers }:

{
  enterpriseName,
  siteName,
  sitePath,
  domains,
  siteTenantsCfg,
}:

let
  inherit (helpers)
    hasAttr
    isNonEmptyString
    requireAttrs
    requireString
    ;

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  attrsOrEmpty = value:
    if builtins.isAttrs value then value else { };

  routedPrefixAttrs =
    { inventoryPrefix, prefixName, family, sourceFile }:
    {
      name = prefixName;
      inherit family sourceFile;
      source = "inventory-routed-prefix";
      intent = {
        kind = "routed-tenant-prefix";
        source = "intent";
      };
      delegatedPrefixLength = inventoryPrefix.delegatedPrefixLength or 64;
      perTenantPrefixLength = inventoryPrefix.perTenantPrefixLength or 64;
      slot = inventoryPrefix.slot or 0;
    }
    // (
      if isNonEmptyString (inventoryPrefix.prefixPostfix or null) then
        { prefixPostfix = inventoryPrefix.prefixPostfix; }
      else
        { }
    )
    // (
      if isNonEmptyString (inventoryPrefix.staticIPv4 or null) then
        { staticIPv4 = inventoryPrefix.staticIPv4; }
      else
        { }
    );

  resolveTenantPrefix =
    tenantName: idx: intentPrefix:
    let
      prefixPath = "${sitePath}.domains.tenants.${tenantName}.routedPrefixes[${toString idx}]";
      intentAttrs = requireAttrs prefixPath intentPrefix;
      prefixName = requireString "${prefixPath}.name" (intentAttrs.name or null);
      family = toString (intentAttrs.family or "ipv6");
      tenantInventory = attrsOrEmpty (siteTenantsCfg.${tenantName} or null);
      inventoryPrefixes = attrsOrEmpty (tenantInventory.routedPrefixes or null);
      inventoryPath =
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.tenants.${tenantName}.routedPrefixes.${prefixName}";
      inventoryPrefix =
        if hasAttr prefixName inventoryPrefixes then
          requireAttrs inventoryPath inventoryPrefixes.${prefixName}
        else
          failInventory inventoryPath "routed prefix '${prefixName}' for tenant '${tenantName}' requires inventory realization";
      sourceFile =
        if isNonEmptyString (inventoryPrefix.sourceFile or null) then
          inventoryPrefix.sourceFile
        else
          failInventory "${inventoryPath}.sourceFile" "sourceFile is required for runtime prefix realization";
    in
    if family != "ipv6" then
      failInventory prefixPath "only family = \"ipv6\" routed prefixes are supported right now"
    else
      routedPrefixAttrs { inherit inventoryPrefix prefixName family sourceFile; };

  tenantNames = map (tenant: requireString "${sitePath}.domains.tenants[].name" (tenant.name or null)) domains.tenants;

  tenantByName = builtins.listToAttrs (
    map (tenant: {
      name = requireString "${sitePath}.domains.tenants[].name" (tenant.name or null);
      value = tenant;
    }) domains.tenants
  );

  resolveForTenant =
    tenantName:
    let
      tenant = attrsOrEmpty (tenantByName.${tenantName} or null);
      intentPrefixes =
        if builtins.isList (tenant.routedPrefixes or null) then tenant.routedPrefixes else [ ];
    in
    builtins.genList (idx: resolveTenantPrefix tenantName idx (builtins.elemAt intentPrefixes idx)) (
      builtins.length intentPrefixes
    );
in
builtins.listToAttrs (
  map (tenantName: {
    name = tenantName;
    value = resolveForTenant tenantName;
  }) tenantNames
)
