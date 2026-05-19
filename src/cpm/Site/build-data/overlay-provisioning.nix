{
  lib,
  helpers,
  common,
  ipam,
  inventoryAttrs,
  allSiteEntries,
  siteAttrs,
  siteOverlays,
  sitePath,
  enterpriseName,
}:

let
  inherit (helpers)
    isNonEmptyString
    sortedNames
    ;

  inherit (common)
    attrsOrEmpty
    listOrEmpty
    uniqueStrings
    ;

  addressPolicy = import ./overlay-address-policy.nix {
    inherit common ipam lib;
  };
  buildOverlayNodeAddresses = import ./overlay-node-addresses.nix {
    inherit addressPolicy common helpers lib;
  };

  overlayReachability = attrsOrEmpty (siteAttrs.overlayReachability or null);
  forwardingOverlayPools = attrsOrEmpty (siteAttrs.overlayAddressPools or null);
  overlayNames = sortedNames overlayReachability;
  enterpriseControlPlaneSites =
    let
      cp = attrsOrEmpty (inventoryAttrs.controlPlane or null);
      sites = attrsOrEmpty (cp.sites or null);
    in
    attrsOrEmpty (sites.${enterpriseName} or null);

  resolvePeerSiteEntry =
    peerSite:
    lib.findFirst
      (entry:
        entry.siteId == peerSite
        || entry.siteDisplayName == peerSite
        || "${entry.enterpriseKey}.${entry.siteKey}" == peerSite)
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
            if
              (prefixAttrs.allocation or "runtime") == "runtime"
              && (prefixAttrs.family or "ipv6") == "ipv6"
              && isNonEmptyString sourceFile
            then
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

  overlayPeerRuntimeRoutedPrefixes =
    peerSites:
    lib.unique (
      lib.concatMap runtimeRoutedPrefixesForPeerSite peerSites
    );

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

  overlayProvisioning =
    builtins.listToAttrs (
      builtins.map
        (overlayName:
          let
            overlayPath = "${sitePath}.overlayReachability.${overlayName}";
            ov = helpers.requireAttrs overlayPath overlayReachability.${overlayName};
            cfg = attrsOrEmpty (siteOverlays.${overlayName} or null);
            peerSites0 = listOrEmpty (ov.peerSites or null);
            peerSites =
              if peerSites0 != [ ] then
                peerSites0
              else if isNonEmptyString (ov.peerSite or null) then
                [ ov.peerSite ]
              else
                [ ];

            terminateOn =
              lib.sort (a: b: a < b) (
                map toString (listOrEmpty (ov.terminateOn or null))
            );

            overlayNodesCfg = attrsOrEmpty (cfg.nodes or null);
            forwardingIpamCfg = attrsOrEmpty (forwardingOverlayPools.${overlayName} or null);

            overlayIpamV4 = attrsOrEmpty (forwardingIpamCfg.ipv4 or null);
            overlayIpamV6 = attrsOrEmpty (forwardingIpamCfg.ipv6 or null);
            addressSourcePolicy = attrsOrEmpty (cfg.addressSourcePolicy or null);
            providerName = if isNonEmptyString (cfg.provider or null) then cfg.provider else null;

            ipamV4Prefix = if isNonEmptyString (overlayIpamV4.prefix or null) then overlayIpamV4.prefix else null;
            ipamV6Prefix = if isNonEmptyString (overlayIpamV6.prefix or null) then overlayIpamV6.prefix else null;

            ipamV4PerNodePrefixLength =
              if builtins.isInt (overlayIpamV4.perNodePrefixLength or null) then
                overlayIpamV4.perNodePrefixLength
              else
                32;

            ipamV6PerNodePrefixLength =
              if builtins.isInt (overlayIpamV6.perNodePrefixLength or null) then
                overlayIpamV6.perNodePrefixLength
              else
                128;

            ipamV4OffsetStart =
              if builtins.isInt (overlayIpamV4.offsetStart or null) then overlayIpamV4.offsetStart else 10;

            ipamV6OffsetStart =
              if builtins.isInt (overlayIpamV6.offsetStart or null) then overlayIpamV6.offsetStart else 10;

            overlayNodeAddrs = buildOverlayNodeAddresses {
              inherit
                addressSourcePolicy
                ipamV4Prefix
                ipamV6Prefix
                overlayNodesCfg
                overlayPath
                terminateOn
                ;
            };
            overlayNodePrefixes = overlayNodePrefixesFor overlayName;
          in
          {
            name = overlayName;
            value =
              {
                name = overlayName;
                peerSite = ov.peerSite or null;
                peerSites = peerSites;
                terminateOn = terminateOn;
                nodes = overlayNodeAddrs;
                nodeRoutePrefixes = overlayNodePrefixes;
                peerRuntimeRoutedPrefixes = overlayPeerRuntimeRoutedPrefixes peerSites;
              }
              // (
                if ipamV4Prefix != null || ipamV6Prefix != null then
                  {
                    ipam =
                      (if ipamV4Prefix != null then
                        {
                          ipv4 =
                            { prefix = ipamV4Prefix; }
                            // (if builtins.isInt (overlayIpamV4.perNodePrefixLength or null) then { perNodePrefixLength = overlayIpamV4.perNodePrefixLength; } else { })
                            // (if builtins.isInt (overlayIpamV4.offsetStart or null) then { offsetStart = overlayIpamV4.offsetStart; } else { });
                        }
                      else
                        { })
                      // (if ipamV6Prefix != null then
                        {
                          ipv6 =
                            { prefix = ipamV6Prefix; }
                            // (if builtins.isInt (overlayIpamV6.perNodePrefixLength or null) then { perNodePrefixLength = overlayIpamV6.perNodePrefixLength; } else { })
                            // (if builtins.isInt (overlayIpamV6.offsetStart or null) then { offsetStart = overlayIpamV6.offsetStart; } else { });
                        }
                      else
                        { });
                  }
                else
                  { }
              )
              // (if isNonEmptyString (cfg.provider or null) then { provider = cfg.provider; } else { })
              // (
                let
                  endpointSourceFiles = attrsOrEmpty (cfg.underlayEndpointSourceFiles or null);
                  endpointSourceFileEntries =
                    (map (sourceFile: { inherit sourceFile; family = 4; }) (listOrEmpty (endpointSourceFiles.ipv4 or null)))
                    ++ (map (sourceFile: { inherit sourceFile; family = 6; }) (listOrEmpty (endpointSourceFiles.ipv6 or null)));
                  endpoints =
                    (uniqueStrings (listOrEmpty (cfg.underlayEndpoints or null)))
                    ++ endpointSourceFileEntries;
                in
                if endpoints != [ ] then { underlayEndpoints = endpoints; } else { }
              )
              // (if providerName != null && builtins.isAttrs (cfg.${providerName} or null) then { ${providerName} = cfg.${providerName}; } else { });
          })
        overlayNames
    );
in
{
  inherit overlayNames overlayProvisioning overlayReachability;
}
