{ lib
, helpers
, common
, allSiteEntries
,
}:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty;

  resolvePeerSiteEntry =
    peerSite:
    lib.findFirst
      (entry: entry.siteId == peerSite || entry.siteDisplayName == peerSite || "${entry.enterpriseKey}.${entry.siteKey}" == peerSite)
      null
      allSiteEntries;

  relationAllowsOverlayToWan =
    overlayName: relation:
    let
      from = attrsOrEmpty (relation.from or null);
      to = attrsOrEmpty (relation.to or null);
      uplinks = listOrEmpty (to.uplinks or null);
    in
    (relation.action or null) == "allow"
    && (relation.trafficType or null) == "any"
    && (from.kind or null) == "external"
    && (from.name or null) == overlayName
    && (to.kind or null) == "external"
    && ((to.name or null) == "wan" || builtins.elem "wan" uplinks);

  peerHasPublicExit =
    overlayName: peerSite:
    let
      peerEntry = resolvePeerSiteEntry peerSite;
      peerSiteAttrs = if peerEntry == null then { } else attrsOrEmpty (peerEntry.site or null);
      contract = attrsOrEmpty (peerSiteAttrs.communicationContract or null);
      relations = listOrEmpty (contract.allowedRelations or contract.relations or null);
    in
    builtins.any (relationAllowsOverlayToWan overlayName) relations;
in
{
  firstPublicExitPeer =
    overlayName: peerSites:
    lib.findFirst (peerHasPublicExit overlayName) null peerSites;
}
