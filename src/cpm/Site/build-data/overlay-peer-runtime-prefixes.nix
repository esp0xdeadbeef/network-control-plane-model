{ lib
, helpers
, common
, allSiteEntries
, inventoryAttrs
, enterpriseName
,
}:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  controlPlaneSites =
    let
      cp = attrsOrEmpty (inventoryAttrs.controlPlane or null);
    in
    attrsOrEmpty (cp.sites or null);

  currentEnterpriseSiteEntries =
    builtins.filter (entry: entry.enterpriseKey == enterpriseName) allSiteEntries;

  resolvePeerSiteEntry =
    peerSite:
    lib.findFirst
      (entry: entry.siteId == peerSite || entry.siteDisplayName == peerSite || "${entry.enterpriseKey}.${entry.siteKey}" == peerSite)
      null
      allSiteEntries;

  runtimeRoutedPrefixesForPeerSite =
    peerSite:
    let
      peerEntry = resolvePeerSiteEntry peerSite;
      peerDomains = if peerEntry == null then { } else attrsOrEmpty (peerEntry.site.domains or null);
      peerTenants = if builtins.isList (peerDomains.tenants or null) then peerDomains.tenants else [ ];
    in
    lib.concatMap
      (tenant:
      let
        tenantAttrs = attrsOrEmpty tenant;
        tenantName = tenantAttrs.name or null;
        routedPrefixes = listOrEmpty (tenantAttrs.routedPrefixes or null);
      in
      lib.concatMap
        (prefix:
        let
          prefixAttrs = attrsOrEmpty prefix;
          sourceFile = prefixAttrs.sourceFile or null;
        in
        if (prefixAttrs.allocation or "runtime") == "runtime" && (prefixAttrs.family or "ipv6") == "ipv6" && isNonEmptyString sourceFile then
          [
            {
              family = 6;
              inherit peerSite;
              inherit sourceFile;
              tenant = tenantName;
              prefixName = prefixAttrs.name or null;
              delegatedPrefixLength = prefixAttrs.delegatedPrefixLength or 64;
              perTenantPrefixLength = prefixAttrs.perTenantPrefixLength or 64;
              slot = prefixAttrs.slot or 0;
            }
          ]
        else
          [ ])
        routedPrefixes)
      peerTenants;

  tenantPrefixesForPeerSite =
    peerSite:
    let
      peerEntry = resolvePeerSiteEntry peerSite;
      peerDomains = if peerEntry == null then { } else attrsOrEmpty (peerEntry.site.domains or null);
      peerTenants = if builtins.isList (peerDomains.tenants or null) then peerDomains.tenants else [ ];
      prefixFor =
        family: tenantName: value:
        if isNonEmptyString value then
          [
            {
              inherit family peerSite tenantName;
              dst = value;
            }
          ]
        else
          [ ];
    in
    lib.concatMap
      (tenant:
      let
        tenantAttrs = attrsOrEmpty tenant;
        tenantName = tenantAttrs.name or null;
      in
      prefixFor 4 tenantName (tenantAttrs.ipv4 or null)
      ++ prefixFor 6 tenantName (tenantAttrs.ipv6 or null))
      peerTenants;
in
rec {
  overlayPeerRuntimeRoutedPrefixes =
    peerSites:
    lib.unique (lib.concatMap runtimeRoutedPrefixesForPeerSite peerSites);

  overlayPeerTenantPrefixes =
    peerSites:
    lib.unique (lib.concatMap tenantPrefixesForPeerSite peerSites);

  overlayNodePrefixRecordsFor =
    overlayName:
    let
      siteOverlayNodeRecords =
        lib.concatMap
          (entry:
            let
              enterpriseSites = attrsOrEmpty (controlPlaneSites.${entry.enterpriseKey} or null);
              siteCfg = attrsOrEmpty (enterpriseSites.${entry.siteKey} or null);
              overlays = attrsOrEmpty (siteCfg.overlays or null);
              overlayCfg = attrsOrEmpty (overlays.${overlayName} or null);
              peerSite = "${entry.enterpriseKey}.${entry.siteKey}";
              recordFor =
                family: node:
                let
                  field = if family == 4 then "addr4" else "addr6";
                  value = node.${field} or null;
                in
                if builtins.isString value && value != "" then
                  [
                    {
                      inherit family overlayName peerSite;
                      overlay = overlayName;
                      dst = value;
                    }
                  ]
                else
                  [ ];
            in
            lib.concatMap
              (node: recordFor 4 node ++ recordFor 6 node)
              (builtins.attrValues (attrsOrEmpty (overlayCfg.nodes or null))))
          currentEnterpriseSiteEntries;
      familyRecords = family: builtins.filter (record: (record.family or null) == family) siteOverlayNodeRecords;
    in
    {
      ipv4 = lib.unique (familyRecords 4);
      ipv6 = lib.unique (familyRecords 6);
    };

  overlayNodePrefixesFor =
    overlayName:
    let
      records = overlayNodePrefixRecordsFor overlayName;
    in
    {
      ipv4 = uniqueStrings (map (record: record.dst) records.ipv4);
      ipv6 = uniqueStrings (map (record: record.dst) records.ipv6);
    };
}
