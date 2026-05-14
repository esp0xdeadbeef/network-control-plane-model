{ lib, helpers, common, ipam }:

let
  inherit (helpers) hasAttr sortedNames;
  addDnsContracts = import ./dns-contracts.nix { inherit lib helpers common; };
in
{
  accessAdvertisements,
  firewallIntent,
  normalizedRuntimeTargets,
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
        value = addDnsContracts (normalizedRuntimeTargets.${targetName} // intentAttrs // advertisementAttrs);
      })
    (sortedNames normalizedRuntimeTargets)
)
