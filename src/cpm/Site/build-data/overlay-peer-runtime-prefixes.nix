{
  lib,
  helpers,
  common,
  allSiteEntries,
  inventoryAttrs,
  enterpriseName,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  enterpriseControlPlaneSites =
    let
      cp = attrsOrEmpty (inventoryAttrs.controlPlane or null);
      sites = attrsOrEmpty (cp.sites or null);
    in
    attrsOrEmpty (sites.${enterpriseName} or null);

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
in
{
  overlayPeerRuntimeRoutedPrefixes =
    peerSites:
    lib.unique (lib.concatMap runtimeRoutedPrefixesForPeerSite peerSites);

  overlayNodePrefixesFor =
    overlayName:
    let
      siteOverlayNodes =
        lib.concatMap
          (siteKey:
            let
              siteCfg = attrsOrEmpty (enterpriseControlPlaneSites.${siteKey} or null);
              overlays = attrsOrEmpty (siteCfg.overlays or null);
              overlayCfg = attrsOrEmpty (overlays.${overlayName} or null);
            in
            builtins.attrValues (attrsOrEmpty (overlayCfg.nodes or null)))
          (sortedNames enterpriseControlPlaneSites);
      nodeAddr = family: node:
        let field = if family == 4 then "addr4" else "addr6";
        in node.${field} or null;
      valid = value: builtins.isString value && value != "";
    in
    {
      ipv4 = uniqueStrings (builtins.filter valid (map (nodeAddr 4) siteOverlayNodes));
      ipv6 = uniqueStrings (builtins.filter valid (map (nodeAddr 6) siteOverlayNodes));
    };
}
