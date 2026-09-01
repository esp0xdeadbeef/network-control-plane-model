{ helpers
, sitePath
, siteAttrs
, routedPrefixesByTenant
, advertisementHelpers
, nat66SourcePrefixes6
,
}:

let
  inherit (helpers) hasAttr requireAttrs requireList requireString sortedNames;
  inherit (advertisementHelpers) failForwarding failInventory stripMask;

  siteDomains = requireAttrs "${sitePath}.domains" (siteAttrs.domains or null);

  tenantDefinitions =
    builtins.listToAttrs (
      builtins.map
        (tenant:
          let
            tenantAttrs = requireAttrs "${sitePath}.domains.tenants[*]" tenant;
            tenantName = requireString "${sitePath}.domains.tenants[*].name" (tenantAttrs.name or null);
          in
          {
            name = tenantName;
            value = tenantAttrs;
          })
        (requireList "${sitePath}.domains.tenants" (siteDomains.tenants or null))
    );

  getRuntimeTargetInterfaces = targetPath: target:
    let
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
    in
    requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);

  getRuntimeTargetInterface = targetPath: target: interfaceName:
    let
      interfaces = getRuntimeTargetInterfaces targetPath target;
    in
    if hasAttr interfaceName interfaces then
      requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}" interfaces.${interfaceName}
    else
      failInventory
        "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}"
        "missing realized tenant interface '${interfaceName}' required for explicit access advertisements";

  validateNoUnexpectedInterfaces = inventoryPath: tenantInterfaceNames: entries:
    let
      tenantInterfaceSet =
        builtins.listToAttrs (builtins.map
          (interfaceName: {
            name = interfaceName;
            value = true;
          })
          tenantInterfaceNames);
    in
    builtins.deepSeq
      (builtins.map
        (interfaceName:
          if hasAttr interfaceName tenantInterfaceSet then
            true
          else
            failInventory "${inventoryPath}.${interfaceName}" "references unknown tenant interface '${interfaceName}'")
        (sortedNames entries))
      true;

  requireCoverage = inventoryPath: tenantInterfaceNames: entries:
    builtins.deepSeq
      (builtins.map
        (interfaceName:
          if hasAttr interfaceName entries then
            true
          else
            failInventory
              "${inventoryPath}.${interfaceName}"
              "missing explicit advertisement realization for tenant interface '${interfaceName}'")
        tenantInterfaceNames)
      true;

  resolveTenantAdvertisementContext = targetPath: target: interfaceName:
    let
      runtimeInterface = getRuntimeTargetInterface targetPath target interfaceName;
      backingRef = advertisementHelpers.attrsOrEmpty (runtimeInterface.backingRef or null);
      tenantName =
        if (backingRef.kind or null) == "attachment" then
          requireString
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.backingRef.name"
            (backingRef.name or null)
        else
          failForwarding
            "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}.backingRef"
            "access advertisements require an explicit tenant-backed interface realization";
      tenantDefinition =
        if hasAttr tenantName tenantDefinitions then
          tenantDefinitions.${tenantName}
        else
          failForwarding
            "${sitePath}.domains.tenants"
            "tenant '${tenantName}' requires an explicit site.domains.tenants entry for advertisement derivation";

      # The summarised internal subnets (the NFM's smallest groupings) carried
      # on the access node's p2p uplink. These are advertised to the clients as
      # RFC 3442 classless routes (IPv4) + RFC 4191 more-specific routes
      # (IPv6), so the clients can reach the rest of the site without a
      # default route. Only the client-facing subnets and the explicitly
      # advertised default belong here; the fabric's point-to-point (/31,
      # /127) and host (/32, /128) plumbing is not client reachability and
      # must never be emitted (RFC 3442 option 121 is capped at 255 bytes,
      # and leaking the fabric plumbing to clients is not modeled).
      internalReachabilityRoutes = family:
        let
          ifaces = getRuntimeTargetInterfaces targetPath target;
          p2pNames = builtins.filter
            (n: ((ifaces.${n}.sourceKind or null) == "p2p"))
            (sortedNames ifaces);
          routes = builtins.concatMap
            (n: (ifaces.${n}.routes or { })."ipv${toString family}" or [ ])
            p2pNames;
          isClientSubnet = r:
            let
              dst = r.dst or null;
              plumbing =
                if !builtins.isString dst then
                  true
                else if family == 4 then
                  (builtins.match ".*/(31|32)$" dst) != null
                else
                  (builtins.match ".*/(127|128)$" dst) != null;
            in
            builtins.isString dst && !plumbing;
        in
        builtins.filter
          (r: isClientSubnet r && ((r.intent.kind or null) == "internal-reachability" || (r.advertisedToClients or false) == true))
          routes;

      # Explicit IPv6 internet egress for this tenant, per FS-400/410/420.
      # Two modeled modes grant a client-facing IPv6 default route:
      #   - routed client GUA (the tenant has a routed IPv6 prefix)
      #   - ULA with tenant-scoped NAT66 (the tenant IPv6 prefix is a modeled
      #     NAT66 source prefix on some core)
      # "No IPv6 internet" tenants advertise no IPv6 default route.
      tenantHasIPv6Egress =
        let
          tenantIpv6 = tenantDefinition.ipv6 or null;
          tenantRouted = routedPrefixesByTenant.${tenantName} or [ ];
          hasRoutedIpv6 = builtins.any
            (prefix: (prefix.family or null) == "ipv6")
            tenantRouted;
          hasNat66 = tenantIpv6 != null && builtins.elem tenantIpv6 nat66SourcePrefixes6;
        in
        hasRoutedIpv6 || hasNat66;
    in
    {
      inherit runtimeInterface tenantName tenantDefinition;
      interfaceAddr4 = stripMask (runtimeInterface.addr4 or null);
      interfaceAddr6 = stripMask (runtimeInterface.addr6 or null);
      tenantIPv4Prefix = tenantDefinition.ipv4 or null;
      tenantIPv6Prefix = tenantDefinition.ipv6 or null;
      tenantRa6Prefixes = tenantDefinition.ra6Prefixes or [ ];
      tenantRoutedPrefixes = routedPrefixesByTenant.${tenantName} or [ ];
      internalReachabilityRoutes4 = internalReachabilityRoutes 4;
      internalReachabilityRoutes6 = internalReachabilityRoutes 6;
      inherit tenantHasIPv6Egress;
    };

in
{
  inherit
    getRuntimeTargetInterfaces
    requireCoverage
    resolveTenantAdvertisementContext
    validateNoUnexpectedInterfaces
    ;
}
