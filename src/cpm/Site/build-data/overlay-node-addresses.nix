{ addressPolicy
, common
, helpers
, lib
,
}:

{ addressSourcePolicy
, ipamV4Prefix
, ipamV6Prefix
, overlayNodeIpamCfg
, overlayNodesCfg
, overlayName
, overlayPath
, terminateOn
,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty failInventory uniqueStrings;

  overlayNodeNames = lib.sort (a: b: a < b) (uniqueStrings (terminateOn ++ sortedNames overlayNodesCfg));

  realizationRecord =
    { addr4, addr6, nodeName }:
    {
      kind = "overlay-participant-address-realization";
      rowId = "FS-350-HDS-010-SDS-010-SMS-050";
      stage = "control-plane-model";
      source = "inventory-realization";
      node = nodeName;
      selectedOverlayIdentity = overlayName;
      participantLedger = {
        source = "nfm-overlay-participant-ledger";
        overlayIdentity = overlayName;
        path = overlayPath;
      };
      classification = {
        kind = "overlay-participant-address";
        delegatedEndpointAuthority = false;
        tenantPrefixAuthority = false;
        providerPrefixAuthority = false;
        forwardingAuthority = false;
      };
      addresses = {
        ipv4 = addr4;
        ipv6 = addr6;
      };
    };

  requireOverlayAddr =
    { field, nodeCfg, nodeIpamCfg, nodeName }:
    let value = nodeIpamCfg.${field} or (nodeCfg.${field} or null);
    in
    if isNonEmptyString value then
      value
    else
      failInventory
        "${overlayPath}.nodes.${nodeName}.${field}"
        "explicit overlay node address is required; NFM owns the pool, inventory must realize the concrete /32 or /128";

  overlayNodeAddrs =
    builtins.listToAttrs (
      builtins.map
        (nodeName:
          let
            nodeCfg = attrsOrEmpty (overlayNodesCfg.${nodeName} or null);
            nodeIpamCfg = attrsOrEmpty (overlayNodeIpamCfg.${nodeName} or null);
            addr4 = requireOverlayAddr { field = "addr4"; inherit nodeCfg nodeIpamCfg nodeName; };
            addr6 = requireOverlayAddr { field = "addr6"; inherit nodeCfg nodeIpamCfg nodeName; };
            _addr4InPool = addressPolicy.validateAddress {
              address = addr4;
              family = 4;
              inherit overlayName;
              inherit nodeName overlayPath;
              prefix = ipamV4Prefix;
            };
            _addr6InPool = addressPolicy.validateAddress {
              address = addr6;
              family = 6;
              inherit overlayName;
              inherit nodeName overlayPath;
              prefix = ipamV6Prefix;
            };
          in
          builtins.seq _addr4InPool (builtins.seq _addr6InPool {
            name = nodeName;
            value =
              {
                inherit addr4 addr6;
                inventoryRealization = realizationRecord { inherit addr4 addr6 nodeName; };
              }
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
      "${overlayPath}.nodes.*.addr"
      (
        builtins.concatLists (
          builtins.map
            (nodeName:
              let node = overlayNodeAddrs.${nodeName};
              in
              [
                { name = "4|${node.addr4}"; value = nodeName; }
                { name = "6|${node.addr6}"; value = nodeName; }
              ])
            (sortedNames overlayNodeAddrs)
        )
      );
in
builtins.seq _uniqueOverlayAddresses overlayNodeAddrs
