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

            explicitOverlayNodeNames =
              lib.sort (a: b: a < b) (
                uniqueStrings ((sortedNames overlayNodesCfg) ++ (sortedNames overlayIpamNodesCfg))
              );

            overlayNodeNames = lib.sort (a: b: a < b) (uniqueStrings (terminateOn ++ explicitOverlayNodeNames));

            resolveOverlayAddr =
              { family, nodeName, idx }:
              let
                nodeCfg = attrsOrEmpty (overlayNodesCfg.${nodeName} or null);
                nodeIpamCfg = attrsOrEmpty (overlayIpamNodesCfg.${nodeName} or null);
                nodeOverrideAddr4 = nodeCfg.addr4 or (nodeIpamCfg.addr4 or null);
                nodeOverrideAddr6 = nodeCfg.addr6 or (nodeIpamCfg.addr6 or null);
              in
              if family == 4 then
                if isNonEmptyString nodeOverrideAddr4 then
                  nodeOverrideAddr4
                else if ipamV4Prefix != null then
                  ipam.allocOne {
                    family = 4;
                    prefix = ipamV4Prefix;
                    perNodePrefixLength = ipamV4PerNodePrefixLength;
                    offset = ipamV4OffsetStart + idx;
                  }
                else
                  null
              else if isNonEmptyString nodeOverrideAddr6 then
                nodeOverrideAddr6
              else if ipamV6Prefix != null then
                ipam.allocOne {
                  family = 6;
                  prefix = ipamV6Prefix;
                  perNodePrefixLength = ipamV6PerNodePrefixLength;
                  offset = ipamV6OffsetStart + idx;
                }
              else
                null;

            overlayNodeAddrs =
              builtins.listToAttrs (
                lib.imap0
                  (idx: nodeName:
                    let
                      addr4 = resolveOverlayAddr { family = 4; inherit nodeName idx; };
                      addr6 = resolveOverlayAddr { family = 6; inherit nodeName idx; };
                    in
                    {
                      name = nodeName;
                      value =
                        { }
                        // (if isNonEmptyString addr4 then { addr4 = addr4; } else { })
                        // (if isNonEmptyString addr6 then { addr6 = addr6; } else { });
                    })
                  overlayNodeNames
              );
          in
          {
            name = overlayName;
            value =
              {
                name = overlayName;
                peerSite = ov.peerSite or null;
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
