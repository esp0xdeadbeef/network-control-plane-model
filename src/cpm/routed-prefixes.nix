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

  attrsOrEmpty = value:
    if builtins.isAttrs value then value else { };

  routedPrefixAttrs =
    { intentPrefix, prefixName, family, sourceFile }:
    {
      name = prefixName;
      inherit family sourceFile;
      source = "intent-routed-prefix";
      intent = {
        kind = "routed-tenant-prefix";
        source = "intent";
      };
      allocation = intentPrefix.allocation or "runtime";
      delegatedPrefixLength = intentPrefix.delegatedPrefixLength or 64;
      perTenantPrefixLength = intentPrefix.perTenantPrefixLength or 64;
      slot = intentPrefix.slot or 0;
    }
    // (
      if isNonEmptyString (intentPrefix.prefixPostfix or null) then
        { prefixPostfix = intentPrefix.prefixPostfix; }
      else
        { }
    )
    // (
      if isNonEmptyString (intentPrefix.staticIPv4 or null) then
        { staticIPv4 = intentPrefix.staticIPv4; }
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
      sourceFile =
        if isNonEmptyString (intentAttrs.sourceFile or null) then
          intentAttrs.sourceFile
        else
          throw "${prefixPath}.sourceFile is required for runtime routed prefix '${prefixName}'";
    in
    if family != "ipv6" then
      throw "${prefixPath}: only family = \"ipv6\" routed prefixes are supported right now"
    else
      routedPrefixAttrs { intentPrefix = intentAttrs; inherit prefixName family sourceFile; };

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
