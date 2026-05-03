{
  helpers,
  failInventory,
  hostsRoot,
}:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    isNonEmptyString
    requireAttrs
    requireString
    sortedNames
    ;

  requireInt = path: value:
    if builtins.isInt value then
      value
    else
      failInventory path "must be an integer";

  buildHostUplinkIndex = hostPath: host:
    let
      uplinks =
        if builtins.isAttrs (host.uplinks or null) then
          requireAttrs "${hostPath}.uplinks" host.uplinks
        else
          { };
    in
    builtins.listToAttrs (
      builtins.map
        (uplinkName:
          let
            uplinkPath = "${hostPath}.uplinks.${uplinkName}";
            uplink = requireAttrs uplinkPath uplinks.${uplinkName};
          in
          {
            name = uplinkName;
            value =
              {
                uplinkName = uplinkName;
                name = uplinkName;
                parent = requireString "${uplinkPath}.parent" (uplink.parent or null);
                bridge = requireString "${uplinkPath}.bridge" (uplink.bridge or null);
              }
              // (if builtins.isAttrs (uplink.ipv4 or null) then { ipv4 = uplink.ipv4; } else { })
              // (if builtins.isAttrs (uplink.ipv6 or null) then { ipv6 = uplink.ipv6; } else { });
          })
        (sortedNames uplinks)
    );

  buildTransitBridgeIndex = hostPath: uplinkIndex: host:
    let
      transitBridges =
        if builtins.isAttrs (host.transitBridges or null) then
          requireAttrs "${hostPath}.transitBridges" host.transitBridges
        else
          { };
    in
    builtins.listToAttrs (
      builtins.map
        (bridgeName:
          let
            bridgePath = "${hostPath}.transitBridges.${bridgeName}";
            bridge = requireAttrs bridgePath transitBridges.${bridgeName};
            parentUplink = requireString "${bridgePath}.parentUplink" (bridge.parentUplink or null);
            _nameCheck =
              if bridge ? name && bridge.name != bridgeName then
                failInventory "${bridgePath}.name" "must equal the attribute name"
              else
                true;
            vlan = requireInt "${bridgePath}.vlan" (bridge.vlan or null);
            _parentCheck =
              if hasAttr parentUplink uplinkIndex then
                true
              else
                failInventory "${bridgePath}.parentUplink" "references unknown uplink '${parentUplink}'";
          in
          builtins.seq _nameCheck (builtins.seq _parentCheck {
            name = bridgeName;
            value = {
              kind = "transitBridge";
              bridge = bridgeName;
              vlan = vlan;
              parentUplink = parentUplink;
            };
          }))
        (sortedNames transitBridges)
    );

  buildGenericBridgeIndex = hostPath: host:
    let
      bridgeNetworks =
        if builtins.isAttrs (host.bridgeNetworks or null) then
          requireAttrs "${hostPath}.bridgeNetworks" host.bridgeNetworks
        else
          { };
    in
    builtins.listToAttrs (
      builtins.map
        (bridgeName:
          let
            bridgePath = "${hostPath}.bridgeNetworks.${bridgeName}";
            bridge = requireAttrs bridgePath bridgeNetworks.${bridgeName};
          in
          {
            name = bridgeName;
            value =
              {
                kind = "bridgeNetwork";
                bridge = bridgeName;
              }
              // (if isNonEmptyString (bridge.parentUplink or null) then { parentUplink = bridge.parentUplink; } else { })
              // (if builtins.isInt (bridge.vlan or null) then { vlan = bridge.vlan; } else { });
          })
        (sortedNames bridgeNetworks)
    );

  buildUplinkBridgeIndex = uplinkIndex:
    builtins.listToAttrs (
      builtins.map
        (uplinkName:
          let
            uplink = uplinkIndex.${uplinkName};
          in
          {
            name = uplink.bridge;
            value = {
              kind = "uplinkBridge";
              bridge = uplink.bridge;
              parentUplink = uplinkName;
            };
          })
        (sortedNames uplinkIndex)
    );

  mergeBridgeIndexes = indexes:
    ensureUniqueEntries
      "inventory.deployment.hosts.*.(transitBridges|bridgeNetworks|uplinks[*].bridge)"
      (builtins.concatLists (
        builtins.map
          (attrs:
            builtins.map
              (name: {
                inherit name;
                value = attrs.${name};
              })
              (sortedNames attrs))
          indexes
      ));

  buildHostIndex = hostName:
    let
      hostPath = "inventory.deployment.hosts.${hostName}";
      host = requireAttrs hostPath hostsRoot.${hostName};
      uplinks = buildHostUplinkIndex hostPath host;
      transitBridges = buildTransitBridgeIndex hostPath uplinks host;
      bridgeNetworks = buildGenericBridgeIndex hostPath host;
      uplinkBridges = buildUplinkBridgeIndex uplinks;
      bridges = mergeBridgeIndexes [ transitBridges bridgeNetworks uplinkBridges ];
    in
    {
      name = hostName;
      value = {
        inherit uplinks bridges;
      };
    };

  hostIndex = builtins.listToAttrs (builtins.map buildHostIndex (sortedNames hostsRoot));

in
{
  inherit hostIndex;
}
