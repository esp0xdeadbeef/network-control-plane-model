{ helpers, common, inventory }:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty;

  collectForSite =
    entry:
    let
      entrySite = attrsOrEmpty (entry.site or null);
      entryDomains = attrsOrEmpty (entrySite.domains or null);
      entryOwnership = attrsOrEmpty (entryDomains.ownership or entrySite.ownership or null);
      entryPrefixes = listOrEmpty (entryOwnership.prefixes or null);
      inventorySite =
        attrsOrEmpty (
          inventory.controlPlane.sites.${entry.enterpriseKey}.${entry.siteKey} or null
        );
      inventoryTenants = attrsOrEmpty (inventorySite.tenants or null);
    in
    builtins.concatLists (
      builtins.map
        (tenantPrefix:
          let
            tenantName = tenantPrefix.name or null;
            intentRoutedPrefixes = listOrEmpty (tenantPrefix.routedPrefixes or null);
            inventoryRoutedPrefixes =
              if isNonEmptyString tenantName then
                attrsOrEmpty (inventoryTenants.${tenantName}.routedPrefixes or null)
              else
                { };
          in
          builtins.concatLists (
            builtins.map
              (intentRoutedPrefix:
                let
                  prefixName = intentRoutedPrefix.name or null;
                  family = toString (intentRoutedPrefix.family or "ipv6");
                  allocation = intentRoutedPrefix.allocation or null;
                  inventoryPrefix =
                    if isNonEmptyString prefixName then
                      attrsOrEmpty (inventoryRoutedPrefixes.${prefixName} or null)
                    else
                      { };
                  sourceFile = inventoryPrefix.sourceFile or null;
                in
                if
                  family == "ipv6"
                  && allocation == "runtime"
                  && isNonEmptyString tenantName
                  && isNonEmptyString prefixName
                  && isNonEmptyString sourceFile
                then
                  [
                    ({
                      inherit family sourceFile;
                      enterpriseName = entry.enterpriseKey;
                      siteName = entry.siteKey;
                      siteId = entry.siteId;
                      tenantName = tenantName;
                      name = prefixName;
                      source = "inventory-routed-prefix";
                      allocation = "runtime";
                      delegatedPrefixLength = inventoryPrefix.delegatedPrefixLength or 64;
                      perTenantPrefixLength = inventoryPrefix.perTenantPrefixLength or 64;
                      slot = inventoryPrefix.slot or 0;
                    }
                    // (
                      if isNonEmptyString (inventoryPrefix.prefixPostfix or null) then
                        { prefixPostfix = inventoryPrefix.prefixPostfix; }
                      else
                        { }
                    ))
                  ]
                else
                  [ ])
              intentRoutedPrefixes
          ))
        entryPrefixes
    );

in
allSiteEntries:
builtins.concatLists (builtins.map collectForSite allSiteEntries)
