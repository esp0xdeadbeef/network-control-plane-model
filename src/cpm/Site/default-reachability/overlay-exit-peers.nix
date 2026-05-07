{
  helpers,
  common,
  allSiteEntries,
  siteAttrs,
  siteOverlayNames,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  resolvePeerSiteEntry =
    peerSite:
    builtins.head (
      builtins.filter
        (entry:
          entry.siteId == peerSite
          || entry.siteDisplayName == peerSite
          || "${entry.enterpriseKey}.${entry.siteKey}" == peerSite)
        allSiteEntries
      ++ [ null ]
    );

  hasRuntimeRoutedIpv6Prefix =
    siteValue:
    let
      ownership = attrsOrEmpty (siteValue.ownership or null);
      prefixes = listOrEmpty (ownership.prefixes or null);
    in
    builtins.any
      (prefix:
        builtins.any
          (routed:
            (routed.family or null) == "ipv6"
            && ((routed.allocation or null) == "runtime" || (routed.source or null) == "inventory-routed-prefix"))
          (listOrEmpty ((attrsOrEmpty prefix).routedPrefixes or null)))
      prefixes;

  overlayPeerSites =
    overlayName:
    let
      overlayReachability = attrsOrEmpty ((attrsOrEmpty (siteAttrs.overlayReachability or null)).${overlayName} or null);
      peerSites = listOrEmpty (overlayReachability.peerSites or null);
      peerSite = overlayReachability.peerSite or null;
    in
    if peerSites != [ ] then peerSites else if helpers.isNonEmptyString peerSite then [ peerSite ] else [ ];

  overlayExitPeerSite =
    overlayName:
    let
      candidates =
        builtins.filter
          (peerSite:
            let peer = resolvePeerSiteEntry peerSite;
            in peer != null && hasRuntimeRoutedIpv6Prefix peer.site)
          (overlayPeerSites overlayName);
    in
    if candidates == [ ] then null else builtins.head candidates;
in
{
  overlayExitPeerSiteByName =
    builtins.listToAttrs (
      builtins.map (overlayName: {
        name = overlayName;
        value = overlayExitPeerSite overlayName;
      }) siteOverlayNames
    );
}
