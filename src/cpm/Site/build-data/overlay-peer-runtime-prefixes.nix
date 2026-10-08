{ lib
, helpers
, common
, allSiteEntries
, inventoryAttrs
, enterpriseName
, siteAttrs
,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  # FS-171 (single writer): the forwarding model is the authoritative writer of
  # the overlay peer route set.  It emits
  # `overlayReachability.<overlay>.routes4/routes6` from the overlay's MODELED
  # imported prefixes (URS: "Overlay transport shall model endpoint identity,
  # permitted peers, bootstrap dependencies, imported and exported prefixes,
  # ..."), each route carrying the concrete peer-site identity (FS-460).  The
  # control plane model consumes that set instead of re-deriving the same
  # prefixes by reaching into the peer site's domains, which both duplicates the
  # computation and only worked when the peer happened to be compiled in.
  overlayReachability = attrsOrEmpty (siteAttrs.overlayReachability or null);

  routesForOverlay =
    overlayName:
    let
      ov = attrsOrEmpty (overlayReachability.${overlayName} or null);
      toEntry =
        family: route:
        {
          inherit family;
          dst = route.dst or null;
          overlay = route.overlay or overlayName;
          peerSite = route.peerSite or ov.peerSite or null;
          tenantName = route.tenant or null;
        }
        // lib.optionalAttrs (route ? sourceFile) {
          sourceFile = route.sourceFile;
          prefixName = route.prefixName or null;
          delegatedPrefixLength = route.delegatedPrefixLength or null;
          perTenantPrefixLength = route.perTenantPrefixLength or null;
          slot = route.slot or null;
        };
    in
    builtins.filter (r: r.dst != null) (
      map (toEntry 4) (listOrEmpty (ov.routes4 or null))
      ++ map (toEntry 6) (listOrEmpty (ov.routes6 or null))
    );

  routesFor =
    overlayNames:
    lib.unique (lib.concatMap routesForOverlay overlayNames);

  isRuntimeRouted =
    route:
    (route.sourceFile or null) != null
    || (route.slot or null) != null;

  controlPlaneSites =
    let
      cp = attrsOrEmpty (inventoryAttrs.controlPlane or null);
    in
    attrsOrEmpty (cp.sites or null);

  currentEnterpriseSiteEntries =
    builtins.filter (entry: entry.enterpriseKey == enterpriseName) allSiteEntries;
in
rec {
  # Overlay peer prefixes, from the forwarding model's single overlay route
  # set.  Runtime-routed (IPv6 delegated) prefixes are those the forwarding
  # model tagged with runtime realization metadata.
  overlayPeerRuntimeRoutedPrefixes =
    overlayNames: builtins.filter isRuntimeRouted (routesFor overlayNames);

  overlayPeerTenantPrefixes =
    overlayNames: builtins.filter (route: !(isRuntimeRouted route)) (routesFor overlayNames);

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
