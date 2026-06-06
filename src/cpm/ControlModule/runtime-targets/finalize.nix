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
      intentAttrs =
        (if hasAttr targetName firewallIntent.natByTarget then { natIntent = firewallIntent.natByTarget.${targetName}; } else { })
        // (if hasAttr targetName firewallIntent.forwardingByTarget then { forwardingIntent = firewallIntent.forwardingByTarget.${targetName}; } else { });
    in
    {
      name = targetName;
      value = addStateContracts targetName (addDnsContracts (normalizedRuntimeTargets.${targetName} // intentAttrs // advertisementAttrs));
    })
    (sortedNames normalizedRuntimeTargets)
)
