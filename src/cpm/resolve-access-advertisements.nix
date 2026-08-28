{ helpers, ipam }:

{ sitePath
, siteAttrs
, runtimeTargets
, realizationIndex
, endpointInventoryIndex
, routedPrefixesByTenant ? { }
,
}:

let
  inherit (helpers) hasAttr requireAttrs requireString sortedNames;

  # Explicit tenant-scoped NAT66 selections, per FS-420. The forwarding model
  # materializes these into each egress node's egressIntent.nat66 from the
  # modeled uplink translation (egress.ipv6.translation.mode = "nat66").
  nat66SourcePrefixes6 = builtins.concatMap
    (targetName:
      let
        target = runtimeTargets.${targetName} or { };
        egress = target.egressIntent or { };
        nat66 = egress.nat66 or { };
      in
      builtins.concatMap
        (uplinkName: (nat66.${uplinkName} or { }).sourcePrefixes or [ ])
        (builtins.attrNames nat66))
    (builtins.attrNames runtimeTargets);

  advertisementHelpers = import ./Unit/access-advertisements/helpers.nix {
    inherit helpers endpointInventoryIndex;
  };
  advertisementContext = import ./Unit/access-advertisements/context.nix {
    inherit helpers sitePath siteAttrs routedPrefixesByTenant advertisementHelpers nat66SourcePrefixes6;
  };
  advertisementEntries = import ./Unit/access-advertisements/entries.nix {
    inherit helpers sitePath ipam advertisementHelpers advertisementContext;
  };
  inherit (advertisementHelpers) failInventory;
  inherit (advertisementContext)
    getRuntimeTargetInterfaces
    requireCoverage
    validateNoUnexpectedInterfaces
    ;
  inherit (advertisementEntries)
    buildExplicitDHCP4Entry
    buildExplicitDHCPv6Entry
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
          inventoryAdvertisements =
            if builtins.isAttrs (inventoryNode.advertisements or null) then
              requireAttrs "${targetDef.nodePath}.advertisements" inventoryNode.advertisements
            else
              { };

          dhcp4Entries =
            if builtins.isAttrs (inventoryAdvertisements.dhcp4 or null) then
              requireAttrs "${targetDef.nodePath}.advertisements.dhcp4" inventoryAdvertisements.dhcp4
            else
              { };
          dhcpv6Entries =
            if builtins.isAttrs (inventoryAdvertisements.dhcpv6 or null) then
              requireAttrs "${targetDef.nodePath}.advertisements.dhcpv6" inventoryAdvertisements.dhcpv6
            else
              { };
          ipv6RaEntries =
            if builtins.isAttrs (inventoryAdvertisements.ipv6Ra or null) then
              requireAttrs "${targetDef.nodePath}.advertisements.ipv6Ra" inventoryAdvertisements.ipv6Ra
            else
              { };
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

          _dhcp4Coverage =
            if dhcp4Entries == { } then true
            else requireCoverage "${targetDef.nodePath}.advertisements.dhcp4" tenantInterfaceNames dhcp4Entries;
          _ipv6RaCoverage =
            if ipv6RaEntries == { } then true
            else requireCoverage "${targetDef.nodePath}.advertisements.ipv6Ra" tenantInterfaceNames ipv6RaEntries;
          _dhcp4NoUnexpected =
            validateNoUnexpectedInterfaces "${targetDef.nodePath}.advertisements.dhcp4" tenantInterfaceNames dhcp4Entries;
          _dhcpv6NoUnexpected =
            validateNoUnexpectedInterfaces "${targetDef.nodePath}.advertisements.dhcpv6" tenantInterfaceNames dhcpv6Entries;
          _ipv6RaNoUnexpected =
            validateNoUnexpectedInterfaces "${targetDef.nodePath}.advertisements.ipv6Ra" tenantInterfaceNames ipv6RaEntries;

          value = {
            dhcp4 =
              builtins.map
                (interfaceName:
                  buildExplicitDHCP4Entry targetDef targetPath target interfaceName dhcp4Entries.${interfaceName})
                tenantInterfaceNames;
            dhcpv6 =
              builtins.map
                (interfaceName:
                  buildExplicitDHCPv6Entry targetDef targetPath target interfaceName dhcpv6Entries.${interfaceName})
                (sortedNames dhcpv6Entries);
            ipv6Ra =
              builtins.map
                (interfaceName:
                  buildExplicitIPv6RaEntry
                    targetDef
                    targetPath
                    target
                    interfaceName
                    ipv6RaEntries.${interfaceName})
                tenantInterfaceNames;
          };
        in
        builtins.seq _dhcp4Coverage (
          builtins.seq _ipv6RaCoverage (
            builtins.seq _dhcp4NoUnexpected (
              builtins.seq _dhcpv6NoUnexpected (
                builtins.seq _ipv6RaNoUnexpected {
                  name = targetName;
                  inherit value;
                }
              )
            )
          )
        );
in
builtins.listToAttrs (
  builtins.filter (entry: entry != null) (builtins.map buildAccessTargetEntry (sortedNames runtimeTargets))
)
