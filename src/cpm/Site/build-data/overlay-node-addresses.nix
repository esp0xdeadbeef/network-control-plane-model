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
, runtimeAddresses
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

  # Provider overlays (e.g. remote egress over WireGuard) inherit their node
  # addresses from the provider profile at runtime. The CPM must not demand a
  # build-time concrete /32 or /128 in that case; the renderer materializes the
  # address from the decrypted provider config instead.
  requireOverlayAddr =
    { field, nodeCfg, nodeIpamCfg, nodeName }:
    let value = nodeIpamCfg.${field} or (nodeCfg.${field} or null);
    in
    if isNonEmptyString value then
      value
    else if runtimeAddresses then
      null
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
            hasStaticAddress = addr4 != null || addr6 != null;
            _addr4InPool =
              if addr4 == null then
                true
              else
                addressPolicy.validateAddress {
                  address = addr4;
                  family = 4;
                  inherit overlayName;
                  inherit nodeName overlayPath;
                  prefix = ipamV4Prefix;
                };
            _addr6InPool =
              if addr6 == null then
                true
              else
                addressPolicy.validateAddress {
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
                addressSource = if hasStaticAddress then "inventory-realization" else "provider-runtime";
              }
              // (if hasStaticAddress then
                {
                  inventoryRealization = realizationRecord { inherit addr4 addr6 nodeName; };
                }
              else
                { })
              // (
                if addr4 != null then
                  addressPolicy.sourceMetadata {
                    address = addr4;
                    family = 4;
                    inherit addressSourcePolicy nodeCfg nodeIpamCfg overlayPath;
                  }
                else
                  { }
              )
              // (
                if addr6 != null then
                  addressPolicy.sourceMetadata {
                    address = addr6;
                    family = 6;
                    inherit addressSourcePolicy nodeCfg nodeIpamCfg overlayPath;
                  }
                else
                  { }
              );
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
              (if node.addr4 == null then [ ] else [ { name = "4|${node.addr4}"; value = nodeName; } ])
              ++ (if node.addr6 == null then [ ] else [ { name = "6|${node.addr6}"; value = nodeName; } ]))
            (sortedNames overlayNodeAddrs)
        )
      );
in
builtins.seq _uniqueOverlayAddresses overlayNodeAddrs
