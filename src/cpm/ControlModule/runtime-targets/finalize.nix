{ lib
, helpers
, common
, ipam
, policyDerivedDnsAllowedClassesForListeners
, policyDerivedDnsForwardersForListeners
, policyDerivedDnsUpstreamRecordsForListeners
,
}:

let
  inherit (helpers) hasAttr sortedNames;
  addDnsContracts = import ./dns-contracts.nix {
    inherit
      lib
      helpers
      common
      policyDerivedDnsAllowedClassesForListeners
      policyDerivedDnsForwardersForListeners
      policyDerivedDnsUpstreamRecordsForListeners
      ;
  };
  addStateContracts = import ./state-contracts.nix {
    inherit common;
  };
in
{ accessAdvertisements
, firewallIntent
, normalizedRuntimeTargets
,
}:
builtins.listToAttrs (
  builtins.map
    (targetName:
    let
      hasAccessAdvertisements = hasAttr targetName accessAdvertisements;
      advertisementAttrs =
        if hasAccessAdvertisements then
          { advertisements = accessAdvertisements.${targetName}; }
        else
          { };
      # FS-410/FS-540: an interface whose modeled MTU is below the Ethernet
      # default cannot carry full-size segments. Publish the clamp set on the
      # target (the renderer reads `clampMssInterfaces`) so tunnels and
      # provider sessions clamp TCP MSS on the forwarding path. WAN clamp
      # authority continues to come from the NAT intent.
      clampMssInterfaces =
        let
          interfaces = common.attrsOrEmpty (
            (common.attrsOrEmpty normalizedRuntimeTargets.${targetName}.effectiveRuntimeRealization or null).interfaces or null
          );
          reduced =
            builtins.filter
              (iface: builtins.isInt (iface.mtu or null) && iface.mtu < 1500)
              (builtins.attrValues interfaces);
        in
        builtins.sort builtins.lessThan (
          common.uniqueStrings (map (iface: iface.runtimeIfName or null) reduced)
        );
      intentAttrs =
        (if hasAttr targetName firewallIntent.natByTarget then { natIntent = firewallIntent.natByTarget.${targetName}; } else { })
        // lib.optionalAttrs (clampMssInterfaces != [ ]) { inherit clampMssInterfaces; }
        // (if hasAttr targetName firewallIntent.forwardingByTarget then { forwardingIntent = firewallIntent.forwardingByTarget.${targetName}; } else { });
    in
    {
      name = targetName;
      value = addStateContracts targetName (addDnsContracts (normalizedRuntimeTargets.${targetName} // intentAttrs // advertisementAttrs));
    })
    (sortedNames normalizedRuntimeTargets)
)
