{
  lib,
  helpers,
  common,
  ipam,
  siteAttrs,
  siteOverlays,
  sitePath,
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
    inherit addressPolicy common helpers ipam lib;
  };

  overlayReachability = attrsOrEmpty (siteAttrs.overlayReachability or null);
  overlayNames = sortedNames overlayReachability;

  overlayProvisioning =
    builtins.listToAttrs (
      builtins.map
        (overlayName:
          let
            overlayPath = "${sitePath}.overlayReachability.${overlayName}";
            ov = helpers.requireAttrs overlayPath overlayReachability.${overlayName};
            cfg = attrsOrEmpty (siteOverlays.${overlayName} or null);

            terminateOn =
              lib.sort (a: b: a < b) (
                map toString (listOrEmpty (ov.terminateOn or null))
              );

            overlayNodesCfg = attrsOrEmpty (cfg.nodes or null);
            overlayIpamCfg = attrsOrEmpty (cfg.ipam or null);
            overlayIpamNodesCfg = attrsOrEmpty (overlayIpamCfg.nodes or null);

            overlayIpamV4 = attrsOrEmpty (overlayIpamCfg.ipv4 or null);
            overlayIpamV6 = attrsOrEmpty (overlayIpamCfg.ipv6 or null);
            addressSourcePolicy = attrsOrEmpty (cfg.addressSourcePolicy or null);
            nebulaCfg = attrsOrEmpty (cfg.nebula or null);
            nebulaLighthouse = attrsOrEmpty (nebulaCfg.lighthouse or null);

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
                ipamV4OffsetStart
                ipamV4PerNodePrefixLength
                ipamV4Prefix
                ipamV6OffsetStart
                ipamV6PerNodePrefixLength
                ipamV6Prefix
                overlayIpamNodesCfg
                overlayNodesCfg
                overlayPath
                terminateOn
                ;
            };
          in
          {
            name = overlayName;
            value =
              {
                name = overlayName;
                peerSite = ov.peerSite or null;
                peerSites = listOrEmpty (ov.peerSites or null);
                terminateOn = terminateOn;
                nodes = overlayNodeAddrs;
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
                  endpoints =
                    uniqueStrings (
                      listOrEmpty (cfg.underlayEndpoints or null)
                      ++ [
                        (nebulaLighthouse.endpoint or null)
                        (nebulaLighthouse.endpoint6 or null)
                      ]
                    );
                in
                if endpoints != [ ] then { underlayEndpoints = endpoints; } else { }
              )
              // (if builtins.isAttrs (cfg.nebula or null) then { nebula = cfg.nebula; } else { });
          })
        overlayNames
    );
in
{
  inherit overlayNames overlayProvisioning overlayReachability;
}
