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
            peerSites0 = listOrEmpty (overlayCfg.peerSites or null);
            peerSites =
              if peerSites0 != [ ] then
                peerSites0
              else if isNonEmptyString (overlayCfg.peerSite or null) then
                [ overlayCfg.peerSite ]
              else
                [ ];
            peerEntryFor =
              peerSite:
              let
                peerSiteEntry = resolvePeerSiteEntry peerSite;
                peerTransit = if peerSiteEntry == null then { } else attrsOrEmpty (peerSiteEntry.site.transit or null);
                peerDomains = if peerSiteEntry == null then { } else attrsOrEmpty (peerSiteEntry.site.domains or null);
                peerTenants = if builtins.isList (peerDomains.tenants or null) then peerDomains.tenants else [ ];
                peerPrefixes4 = uniqueStrings (builtins.filter isNonEmptyString (builtins.map (tenant: (attrsOrEmpty tenant).ipv4 or null) peerTenants));
                peerPrefixes6 = uniqueStrings (builtins.filter isNonEmptyString (builtins.map (tenant: (attrsOrEmpty tenant).ipv6 or null) peerTenants));
              in
              {
                inherit peerSite peerPrefixes4 peerPrefixes6;
                byNode = transitEndpointAddressesByNodeForTransit peerTransit;
              };
            peerEntries = builtins.map peerEntryFor peerSites;
            peerPrefixes4 = uniqueStrings (builtins.concatMap (entry: entry.peerPrefixes4) peerEntries);
            peerPrefixes6 = uniqueStrings (builtins.concatMap (entry: entry.peerPrefixes6) peerEntries);
            mergeByNode =
              acc: entry:
              builtins.foldl'
                (state: nodeName:
                  let
                    existing =
                      if builtins.hasAttr nodeName state then
                        state.${nodeName}
                      else
                        {
                          ipv4 = [ ];
                          ipv6 = [ ];
                        };
                    node = entry.byNode.${nodeName};
                  in
                  state
                  // {
                    ${nodeName} = {
                      ipv4 = uniqueStrings (existing.ipv4 ++ listOrEmpty (node.ipv4 or null));
                      ipv6 = uniqueStrings (existing.ipv6 ++ listOrEmpty (node.ipv6 or null));
                    };
                  })
                acc
                (sortedNames entry.byNode);
          in
          {
            name = overlayName;
            value = {
              underlayEndpoints = listOrEmpty (overlayCfg.underlayEndpoints or null);
              peerSite = if peerSites == [ ] then null else builtins.head peerSites;
              peerSites = peerSites;
              inherit peerEntries peerPrefixes4 peerPrefixes6;
              byNode = builtins.foldl' mergeByNode { } peerEntries;
            };
          })
        overlayNames
    );
in
{
  inherit overlayTransitEndpointAddressesByOverlay;
}
