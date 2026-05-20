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

  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  addressPolicy = import ./overlay-address-policy.nix {
    inherit common ipam lib;
  };
  buildOverlayNodeAddresses = import ./overlay-node-addresses.nix {
    inherit addressPolicy common helpers lib;
  };
  peerRuntimePrefixes = import ./overlay-peer-runtime-prefixes.nix {
    inherit lib helpers common allSiteEntries inventoryAttrs enterpriseName;
  };
  publicExitPeer = import ./overlay-public-exit-peer.nix {
    inherit lib helpers common allSiteEntries;
  };
  inherit (peerRuntimePrefixes) overlayNodePrefixesFor overlayPeerRuntimeRoutedPrefixes;

  overlayReachability = attrsOrEmpty (siteAttrs.overlayReachability or null);
  forwardingOverlayPools = attrsOrEmpty (siteAttrs.overlayAddressPools or null);
  overlayNames = sortedNames overlayReachability;

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
            overlayNodeIpamCfg = attrsOrEmpty ((attrsOrEmpty (cfg.ipam or null)).nodes or null);
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
                overlayNodeIpamCfg
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
                publicExitPeerSite = publicExitPeer.firstPublicExitPeer overlayName peerSites;
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
