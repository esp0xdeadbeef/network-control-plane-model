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
      #
      # DEDUPLICATED BY DESTINATION. The same internal-reachability prefix is
      # carried on several of the access node's point-to-point interfaces (the
      # downstream and upstream selector legs each hold an installable route to
      # it), so concatenating the per-interface lists without compaction
      # emitted the same destination two or more times. Measured on the neon
      # inventory: `advertisements.ipv6Ra[0].moreSpecificRoutes` carried
      # `fd42:dead:beef:390::/64` (the unlock tenant, where FS-100 places the
      # Tang box) twice and the whole set twice over.
      #
      # That list is consumed verbatim by the renderer, which emits one radvd
      # `route <prefix> { ... }` stanza per entry
      # (`network-renderer-nixos/s88/ControlModule/access/render/radvd.nix`).
      # A duplicate entry is therefore a duplicate RFC 4191 Route Information
      # Option for one prefix: noise the tenant must parse repeatedly, and a
      # second, independently-lifetimed route for the same destination that a
      # client may install over the first. Cross-tenant reachability is a
      # contract (FS-100: Tang in the unlock tenant is reachable from every
      # access tenant), so it must be advertised once, deterministically.
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
          selected = builtins.filter
            (r: isClientSubnet r && ((r.intent.kind or null) == "internal-reachability" || (r.advertisedToClients or false) == true))
            routes;
          # Order-preserving unique by `dst`. The accepted routes are a few
          # dozen at most, so a quadratic insert is clearer than a
          # listToAttrs round trip and does not reorder the output (the
          # rendered radvd stanzas should stay stable across evaluations).
          uniqueByDst =
            seen: acc: remaining:
            if remaining == [ ] then
              acc
            else
              let
                head = builtins.head remaining;
                dst = head.dst or null;
                rest = builtins.tail remaining;
              in
              if builtins.elem dst seen then
                uniqueByDst seen acc rest
              else
                uniqueByDst (seen ++ [ dst ]) (acc ++ [ head ]) rest;
        in
        uniqueByDst [ ] [ ] selected;

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
      # FS-560: the tenant DNS domain (search/namespace) is modeled in
      # intent.nix ownership prefixes and flows through the forwarding-model
      # domains table. It is never a renderer-local default.
      dnsDomain = tenantDefinition.dnsDomain or null;
      # Search-domain LIST: the tenant's own namespace plus its shared parent
      # zone, derived by the compiler (compiler-output tenants[].domainSearch).
      # Falls back to the single domain when the compiled list is absent.
      domainSearch =
        if builtins.isList (tenantDefinition.domainSearch or null) then
          tenantDefinition.domainSearch
        else if (tenantDefinition.dnsDomain or null) != null then
          [ tenantDefinition.dnsDomain ]
        else
          [ ];
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
