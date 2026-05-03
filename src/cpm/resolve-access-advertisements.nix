{ helpers }:

{
  sitePath,
  siteAttrs,
  runtimeTargets,
  realizationIndex,
  endpointInventoryIndex,
  routedPrefixesByTenant ? { },
}:

let
  inherit (helpers) hasAttr requireAttrs requireString sortedNames;

  advertisementHelpers = import ./Unit/access-advertisements/helpers.nix {
    inherit helpers endpointInventoryIndex;
  };
  advertisementContext = import ./Unit/access-advertisements/context.nix {
    inherit helpers sitePath siteAttrs routedPrefixesByTenant advertisementHelpers;
  };
  advertisementEntries = import ./Unit/access-advertisements/entries.nix {
    inherit helpers sitePath advertisementHelpers advertisementContext;
  };
  inherit (advertisementHelpers) failInventory;
  inherit (advertisementContext)
    getRuntimeTargetInterfaces
    requireCoverage
    validateNoUnexpectedInterfaces
    ;
  inherit (advertisementEntries)
    buildExplicitDHCP4Entry
    buildExplicitIPv6RaEntry
    ;

  buildAccessTargetEntry = targetName:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      target = requireAttrs targetPath runtimeTargets.${targetName};
      role = target.role or null;
    in
    if role != "access" then
      null
    else
      let
        placement = requireAttrs "${targetPath}.placement" (target.placement or null);
        placementKind = placement.kind or null;
      in
      if placementKind != "inventory-realization" then
        null
      else
        let
          targetId = requireString "${targetPath}.placement.target" (placement.target or null);
          targetDef =
            if hasAttr targetId realizationIndex.targetDefs then
              realizationIndex.targetDefs.${targetId}
            else
              failInventory
                "inventory.realization.nodes.${targetId}"
                "access runtime target '${targetId}' must be explicitly realized";

          inventoryNode = requireAttrs targetDef.nodePath targetDef.node;
          externalValidation =
            if builtins.isAttrs (inventoryNode.externalValidation or null) then
              inventoryNode.externalValidation
            else
              { };
          inventoryAdvertisements =
            if builtins.isAttrs (inventoryNode.advertisements or null) then
              requireAttrs "${targetDef.nodePath}.advertisements" inventoryNode.advertisements
            else
              failInventory
                "${targetDef.nodePath}.advertisements"
                "access runtime target '${targetId}' requires explicit advertisements realization";

          dhcp4Entries = requireAttrs "${targetDef.nodePath}.advertisements.dhcp4" (inventoryAdvertisements.dhcp4 or null);
          ipv6RaEntries = requireAttrs "${targetDef.nodePath}.advertisements.ipv6Ra" (inventoryAdvertisements.ipv6Ra or null);
          interfaces = getRuntimeTargetInterfaces targetPath target;
          tenantInterfaceNames =
            builtins.filter
              (interfaceName:
                let
                  iface =
                    requireAttrs
                      "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
                      interfaces.${interfaceName};
                in
                (iface.sourceKind or null) == "tenant")
              (sortedNames interfaces);

          _dhcp4Coverage = requireCoverage "${targetDef.nodePath}.advertisements.dhcp4" tenantInterfaceNames dhcp4Entries;
          _ipv6RaCoverage = requireCoverage "${targetDef.nodePath}.advertisements.ipv6Ra" tenantInterfaceNames ipv6RaEntries;
          _dhcp4NoUnexpected =
            validateNoUnexpectedInterfaces "${targetDef.nodePath}.advertisements.dhcp4" tenantInterfaceNames dhcp4Entries;
          _ipv6RaNoUnexpected =
            validateNoUnexpectedInterfaces "${targetDef.nodePath}.advertisements.ipv6Ra" tenantInterfaceNames ipv6RaEntries;

          value = {
            inherit externalValidation;
            dhcp4 =
              builtins.map
                (interfaceName:
                  buildExplicitDHCP4Entry targetDef targetPath target interfaceName dhcp4Entries.${interfaceName})
                tenantInterfaceNames;
            ipv6Ra =
              builtins.map
                (interfaceName:
                  buildExplicitIPv6RaEntry
                    targetDef
                    targetPath
                    target
                    interfaceName
                    ipv6RaEntries.${interfaceName}
                    externalValidation)
                tenantInterfaceNames;
          };
        in
        builtins.seq _dhcp4Coverage (
          builtins.seq _ipv6RaCoverage (
            builtins.seq _dhcp4NoUnexpected (
              builtins.seq _ipv6RaNoUnexpected {
                name = targetName;
                inherit value;
              }
            )
          )
        );
in
builtins.listToAttrs (
  builtins.filter (entry: entry != null) (builtins.map buildAccessTargetEntry (sortedNames runtimeTargets))
)
