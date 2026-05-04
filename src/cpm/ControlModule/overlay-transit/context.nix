{
  lib,
  helpers,
  common,
  allSiteEntries,
  sitePath,
  overlayNames,
  overlayProvisioning,
}:

let
  inherit (helpers) isNonEmptyString requireList requireString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  resolvePeerSiteEntry =
    peerSite:
    lib.findFirst
      (entry:
        entry.siteId == peerSite
        || entry.siteDisplayName == peerSite
        || "${entry.enterpriseKey}.${entry.siteKey}" == peerSite)
      null
      allSiteEntries;

  transitEndpointAddressesByNodeForTransit =
    transitValue:
    builtins.foldl'
      (acc: adjacency:
        let
          endpoints = requireList "${sitePath}.transit.adjacencies[*].endpoints" (adjacency.endpoints or null);
          applyEndpoint =
            state: endpoint:
            let
              nodeName = requireString "${sitePath}.transit.adjacencies[*].endpoints[*].unit" (endpoint.unit or null);
              local = attrsOrEmpty (endpoint.local or null);
              existing = if builtins.hasAttr nodeName state then state.${nodeName} else { ipv4 = [ ]; ipv6 = [ ]; };
            in
            state
            // {
              ${nodeName} = {
                ipv4 = if isNonEmptyString (local.ipv4 or null) then uniqueStrings (existing.ipv4 ++ [ local.ipv4 ]) else existing.ipv4;
                ipv6 = if isNonEmptyString (local.ipv6 or null) then uniqueStrings (existing.ipv6 ++ [ local.ipv6 ]) else existing.ipv6;
              };
            };
        in
        builtins.foldl' applyEndpoint acc endpoints)
      { }
      (listOrEmpty (transitValue.adjacencies or null));

  overlayTransitEndpointAddressesByOverlay =
    builtins.listToAttrs (
      builtins.map
        (overlayName:
          let
            overlayCfg = attrsOrEmpty (overlayProvisioning.${overlayName} or null);
            peerSite = overlayCfg.peerSite or null;
            peerSiteEntry = if isNonEmptyString peerSite then resolvePeerSiteEntry peerSite else null;
            peerTransit = if peerSiteEntry == null then { } else attrsOrEmpty (peerSiteEntry.site.transit or null);
            peerDomains = if peerSiteEntry == null then { } else attrsOrEmpty (peerSiteEntry.site.domains or null);
            peerTenants = if builtins.isList (peerDomains.tenants or null) then peerDomains.tenants else [ ];
            peerPrefixes4 = uniqueStrings (builtins.filter isNonEmptyString (builtins.map (tenant: (attrsOrEmpty tenant).ipv4 or null) peerTenants));
            peerPrefixes6 = uniqueStrings (builtins.filter isNonEmptyString (builtins.map (tenant: (attrsOrEmpty tenant).ipv6 or null) peerTenants));
          in
          {
            name = overlayName;
            value = {
              underlayEndpoints = listOrEmpty (overlayCfg.underlayEndpoints or null);
              inherit peerSite peerPrefixes4 peerPrefixes6;
              byNode = transitEndpointAddressesByNodeForTransit peerTransit;
            };
          })
        overlayNames
    );
in
{
  inherit overlayTransitEndpointAddressesByOverlay;
}
