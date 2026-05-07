{ lib, helpers, common, ipam }:

let
  inherit (helpers) hasAttr sortedNames;
  addDnsContracts = import ./dns-contracts.nix { inherit lib helpers common ipam; };
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
        accessExternalValidation =
          if !hasAccessAdvertisements then
            { }
          else
            accessAdvertisements.${targetName}.externalValidation or { };
        wantsDelegatedIPv6Prefix =
          (accessExternalValidation.delegatedIPv6Prefix or false)
          || (accessExternalValidation.delegatedIPv6Prefixes or false);
        delegatedPrefixExternalValidation =
          accessExternalValidation
          // {
            delegatedPrefixSecretName = "access-node-ipv6-prefix-${targetName}";
            delegatedPrefixSecretPath = "/run/secrets/access-node-ipv6-prefix-${targetName}";
          };
        delegatedPrefixAdvertisements =
          accessAdvertisements.${targetName}
          // {
            externalValidation = delegatedPrefixExternalValidation;
            ipv6Ra =
              builtins.map
                (entry: entry // { externalValidation = delegatedPrefixExternalValidation; })
                (accessAdvertisements.${targetName}.ipv6Ra or [ ]);
          };
        advertisementAttrs =
          if wantsDelegatedIPv6Prefix then
            {
              advertisements = delegatedPrefixAdvertisements;
              externalValidation = delegatedPrefixExternalValidation;
            }
          else if hasAccessAdvertisements then
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
