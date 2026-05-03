{
  helpers,
  common,
  resolveRoutedPrefixes,
  enterpriseName,
  siteName,
  sitePath,
  domains,
  siteTenantsCfg,
  siteIpv6Cfg,
  uplinkNames,
}:

let
  inherit (helpers) isNonEmptyString requireString;
  inherit (common) attrsOrEmpty failInventory;

  parsePrefixLen =
    prefix:
    let
      m = builtins.match ".*/([0-9]+)$" (toString prefix);
    in
    if m == null then null else builtins.fromJSON (builtins.head m);

  validatePrefixLen =
    { path, prefix, expected }:
    let
      len = parsePrefixLen prefix;
    in
    if len == null then
      failInventory path "prefix '${toString prefix}' must include a /<len> suffix"
    else if len != expected then
      failInventory path "prefix '${toString prefix}' must be a /${toString expected}"
    else
      true;

  ipv6PdCfg = attrsOrEmpty (siteIpv6Cfg.pd or null);

  ipv6PdUplink =
    if isNonEmptyString (ipv6PdCfg.uplink or null) then toString ipv6PdCfg.uplink else null;

  ipv6PdDelegatedPrefixLength =
    if ipv6PdUplink == null then
      null
    else if builtins.isInt (ipv6PdCfg.delegatedPrefixLength or null) then
      ipv6PdCfg.delegatedPrefixLength
    else
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd.delegatedPrefixLength"
        "ipv6.pd.delegatedPrefixLength is required and must be an integer when ipv6.pd.uplink is set";

  ipv6PdPerTenantPrefixLength =
    if ipv6PdUplink == null then
      null
    else if builtins.isInt (ipv6PdCfg.perTenantPrefixLength or null) then
      ipv6PdCfg.perTenantPrefixLength
    else
      64;

  _validatePdUplink =
    if ipv6PdUplink == null then
      true
    else if builtins.elem ipv6PdUplink uplinkNames then
      true
    else
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd.uplink"
        "ipv6.pd.uplink '${ipv6PdUplink}' must match a declared site uplink name: ${builtins.toJSON uplinkNames}";

  _validatePdPrefixLengths =
    if ipv6PdUplink == null then
      true
    else if ipv6PdDelegatedPrefixLength < 48 || ipv6PdDelegatedPrefixLength > 64 then
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd.delegatedPrefixLength"
        "delegatedPrefixLength must be between /48 and /64 (got /${toString ipv6PdDelegatedPrefixLength})"
    else if ipv6PdPerTenantPrefixLength < ipv6PdDelegatedPrefixLength || ipv6PdPerTenantPrefixLength > 64 then
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd.perTenantPrefixLength"
        "perTenantPrefixLength must be between delegatedPrefixLength and /64 (got /${toString ipv6PdPerTenantPrefixLength})"
    else
      true;

  pdSlotCount =
    if ipv6PdUplink == null then
      0
    else
      let
        diff = ipv6PdPerTenantPrefixLength - ipv6PdDelegatedPrefixLength;
        pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);
      in
      pow2 diff;

  tenantNames = map (t: requireString "${sitePath}.domains.tenants[].name" (t.name or null)) domains.tenants;

  routedPrefixesByTenant = resolveRoutedPrefixes {
    inherit enterpriseName siteName sitePath domains siteTenantsCfg;
  };

  tenantIpv6Mode =
    tenantName:
    let
      tcfg = attrsOrEmpty (siteTenantsCfg.${tenantName} or null);
      v6 = attrsOrEmpty (tcfg.ipv6 or null);
      mode = v6.mode or null;
    in
    if ipv6PdUplink == null then
      (if builtins.isString mode && mode != "" then toString mode else "slaac")
    else if builtins.isString mode && mode != "" then
      let
        m = toString mode;
      in
      if m == "slaac" || m == "dhcpv6" || m == "static" then
        m
      else
        failInventory
          "inventory.controlPlane.sites.${enterpriseName}.${siteName}.tenants.${tenantName}.ipv6.mode"
          "ipv6.mode must be one of: \"slaac\", \"dhcpv6\", \"static\" (got ${builtins.toJSON mode})"
    else
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.tenants.${tenantName}.ipv6.mode"
        "ipv6.mode is required when ipv6.pd.uplink is set";

  tenantStaticPrefixes =
    tenantName:
    let
      tcfg = attrsOrEmpty (siteTenantsCfg.${tenantName} or null);
      v6 = attrsOrEmpty (tcfg.ipv6 or null);
      prefixes = v6.prefixes or null;
      path = "inventory.controlPlane.sites.${enterpriseName}.${siteName}.tenants.${tenantName}.ipv6.prefixes";
    in
    if tenantIpv6Mode tenantName != "static" then
      [ ]
    else if builtins.isList prefixes then
      builtins.seq
        (builtins.foldl' (acc: p: builtins.seq (validatePrefixLen { path = path; prefix = p; expected = 64; }) acc) true prefixes)
        (map toString prefixes)
    else
      failInventory path "ipv6.prefixes is required (list of /64s) when ipv6.mode = \"static\"";

  pdTenants =
    if ipv6PdUplink == null then [ ] else builtins.sort (a: b: a < b) (builtins.filter (t: tenantIpv6Mode t != "static") tenantNames);

  _validatePdSlotsEnough =
    if ipv6PdUplink == null then
      true
    else if builtins.length pdTenants <= pdSlotCount then
      true
    else
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.ipv6.pd"
        "not enough PD /${toString ipv6PdPerTenantPrefixLength} slots in delegated /${toString ipv6PdDelegatedPrefixLength} for ${toString (builtins.length pdTenants)} tenants (capacity ${toString pdSlotCount})";

  pdTenantSlots = builtins.listToAttrs (
    builtins.genList (idx: { name = builtins.elemAt pdTenants idx; value = idx; }) (builtins.length pdTenants)
  );
in
{
  inherit routedPrefixesByTenant;
  ipv6Plan =
    builtins.seq _validatePdUplink (
      builtins.seq _validatePdPrefixLengths (
        builtins.seq _validatePdSlotsEnough (
          if ipv6PdUplink == null then
            null
          else
            {
              pd = {
                uplink = ipv6PdUplink;
                delegatedPrefixLength = ipv6PdDelegatedPrefixLength;
                perTenantPrefixLength = ipv6PdPerTenantPrefixLength;
                tenantSlots = pdTenantSlots;
              };
              tenants = builtins.listToAttrs (
                map (tenantName:
                  let
                    mode = tenantIpv6Mode tenantName;
                  in
                  {
                    name = tenantName;
                    value =
                      { inherit mode; }
                      // (if mode == "static" then
                        { prefixes = tenantStaticPrefixes tenantName; }
                      else
                        { pd = { slot = pdTenantSlots.${tenantName}; prefixLength = ipv6PdPerTenantPrefixLength; }; });
                  }) tenantNames
              );
            }
        )
      )
    );
}
