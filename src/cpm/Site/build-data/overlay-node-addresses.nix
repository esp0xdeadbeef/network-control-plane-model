{
  addressPolicy,
  common,
  helpers,
  ipam,
  lib,
}:

{
  addressSourcePolicy,
  ipamV4OffsetStart,
  ipamV4PerNodePrefixLength,
  ipamV4Prefix,
  ipamV6OffsetStart,
  ipamV6PerNodePrefixLength,
  ipamV6Prefix,
  overlayIpamNodesCfg,
  overlayNodesCfg,
  overlayPath,
  terminateOn,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty uniqueStrings;

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
            nodeCfg = attrsOrEmpty (overlayNodesCfg.${nodeName} or null);
            nodeIpamCfg = attrsOrEmpty (overlayIpamNodesCfg.${nodeName} or null);
            addr4 = resolveOverlayAddr { family = 4; inherit nodeName idx; };
            addr6 = resolveOverlayAddr { family = 6; inherit nodeName idx; };
            _addr4InPool = addressPolicy.validateAddress {
              address = addr4;
              family = 4;
              inherit nodeName overlayPath;
              prefix = ipamV4Prefix;
            };
            _addr6InPool = addressPolicy.validateAddress {
              address = addr6;
              family = 6;
              inherit nodeName overlayPath;
              prefix = ipamV6Prefix;
            };
          in
          builtins.seq _addr4InPool (builtins.seq _addr6InPool {
            name = nodeName;
            value =
              { }
              // (if isNonEmptyString addr4 then { addr4 = addr4; } else { })
              // (if isNonEmptyString addr6 then { addr6 = addr6; } else { })
              // addressPolicy.sourceMetadata {
                address = addr4;
                family = 4;
                inherit addressSourcePolicy nodeCfg nodeIpamCfg overlayPath;
              }
              // addressPolicy.sourceMetadata {
                address = addr6;
                family = 6;
                inherit addressSourcePolicy nodeCfg nodeIpamCfg overlayPath;
              };
          }))
        overlayNodeNames
    );

  _uniqueOverlayAddresses =
    helpers.ensureUniqueEntries
      "${overlayPath}.ipam.nodes.*.addr"
      (
        builtins.concatLists (
          builtins.map
            (nodeName:
              let node = overlayNodeAddrs.${nodeName};
              in
              (if isNonEmptyString (node.addr4 or null) then [ { name = "4|${node.addr4}"; value = nodeName; } ] else [ ])
              ++ (if isNonEmptyString (node.addr6 or null) then [ { name = "6|${node.addr6}"; value = nodeName; } ] else [ ]))
            (sortedNames overlayNodeAddrs)
        )
      );
in
builtins.seq _uniqueOverlayAddresses overlayNodeAddrs
