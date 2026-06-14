{ lib
, helpers
, common
, ipam
, resolveAccessAdvertisements
, resolvePolicyEndpointBindings
, resolveFirewallIntent
, sitePath
, siteAttrs
, attachments
, domains
, realizationIndex
, endpointInventoryIndex
, routedPrefixesByTenant
, dnsServiceRouteSpecs
, providerEndpointForServiceProvider
, providerTenantsForServiceProvider
, policyDerivedDnsAllowedClassesForListeners
, policyDerivedDnsForwardersForListeners
, policyDerivedDnsUpstreamRecordsForListeners
, normalizeRuntimeTargetRoutes
, normalizeRuntimeTargetRoutesAfterPolicyComplements
, normalizedRuntimeTargets
,
}:

let
  inherit (common) uniqueStrings;

  accessAdvertisements =
    resolveAccessAdvertisements {
      inherit sitePath siteAttrs realizationIndex endpointInventoryIndex routedPrefixesByTenant;
      runtimeTargets = normalizedRuntimeTargets;
    };

  policyEndpointBindings =
    resolvePolicyEndpointBindings {
      inherit sitePath siteAttrs attachments domains;
      runtimeTargets = normalizedRuntimeTargets;
    };

  dnsServiceUplinks = import ../../ControlModule/dns-policy/service-uplinks.nix {
    inherit lib uniqueStrings dnsServiceRouteSpecs;
  };

  resolvedServices = import ./services.nix {
    inherit
      lib
      helpers
      common
      uniqueStrings
      policyEndpointBindings
      providerEndpointForServiceProvider
      providerTenantsForServiceProvider
      sitePath
      ;
    inherit (dnsServiceUplinks)
      preferredDnsUplinksByRelationForService
      preferredDnsUplinksForService
      ;
  };

  finalizeRuntimeTargets = import ../../ControlModule/runtime-targets/finalize.nix {
    inherit
      lib
      helpers
      common
      ipam
      policyDerivedDnsAllowedClassesForListeners
      policyDerivedDnsForwardersForListeners
      policyDerivedDnsUpstreamRecordsForListeners
      ;
  };

  runtimeTargetsForFirewall =
    finalizeRuntimeTargets {
      inherit accessAdvertisements;
      firewallIntent = {
        natByTarget = { };
        forwardingByTarget = { };
      };
      inherit normalizedRuntimeTargets;
    };

  firewallIntent =
    resolveFirewallIntent {
      services = resolvedServices;
      inherit sitePath siteAttrs policyEndpointBindings;
      runtimeTargets = runtimeTargetsForFirewall;
    };

  routeDnsServiceReachability = import ../../ControlModule/runtime-targets/dns-service-routes.nix {
    inherit lib common ipam;
  };

  routeAugmentedRuntimeTargets =
    routeDnsServiceReachability {
      inherit firewallIntent normalizedRuntimeTargets;
      services = resolvedServices;
    };

  runtimeTargetsWithIntent =
    finalizeRuntimeTargets {
      inherit accessAdvertisements firewallIntent;
      normalizedRuntimeTargets = routeAugmentedRuntimeTargets;
    };

  addCoreTenantReturnRoutes =
    rtAttrs:
    lib.mapAttrs
      (targetName: target:
        let
          natIntent = target.natIntent or {};
          masqPrefixes4 = natIntent.masqueradeSourcePrefixes4 or [];
          role = target.role or "";
          isCore = builtins.substring 0 4 role == "core";
          interfaces = (target.effectiveRuntimeRealization or {}).interfaces or {};
          isFabricP2p = iface:
            (iface.sourceKind or "") == "p2p"
            && ((iface.backingRef or {}).lane or {}).uplink or "" != "wan";
          peer4For = addr:
            let
              parts = lib.splitString "/" addr;
              addrStr = if builtins.length parts >= 1 then builtins.elemAt parts 0 else "";
              octets = lib.splitString "." addrStr;
            in
            if builtins.length octets != 4 then null
            else
              let
                lastOctet = builtins.elemAt octets 3;
                lastInt = lib.toInt (if lastOctet == "" then "0" else lastOctet);
                peerInt = if lib.mod lastInt 2 == 0 then lastInt + 1 else lastInt - 1;
                peerOctets = builtins.genList
                  (i: if i == 3 then builtins.toString peerInt else builtins.elemAt octets i)
                  4;
              in builtins.concatStringsSep "." peerOctets;
        in
        if !isCore || masqPrefixes4 == [] then
          target
        else
          let
            updatedInterfaces =
              builtins.mapAttrs
                (ifName: iface:
                  if !(isFabricP2p iface) then
                    iface
                  else
                    let
                      peer4 = peer4For (iface.addr4 or "");
                      routes = iface.routes or {};
                      tenantRoutes =
                        if peer4 == null then []
                        else builtins.map
                          (prefix: {
                            dst = prefix;
                            proto = "internal";
                            via4 = peer4;
                            intent = {
                              kind = "internal-reachability";
                              source = "tenant-subnet-return";
                            };
                          })
                          masqPrefixes4;
                      ipv4 = (routes.ipv4 or []) ++ tenantRoutes;
                      ipv6 = routes.ipv6 or [];
                    in
                    iface // { routes = routes // { inherit ipv4 ipv6; }; }
                )
                interfaces;
          in
          target // {
            effectiveRuntimeRealization =
              (target.effectiveRuntimeRealization or {}) // {
                interfaces = updatedInterfaces;
              };
          }
      )
      rtAttrs;

  # ── Provider-network route injection ──
  # Scan ALL runtime-target services for provider handoff addressing
  # (providerAddress / customerAddress fields at the server or service level).
  # PPPoE is one input source; any future provider handoff type that supplies
  # these fields gets fabric routes automatically.
  #
  # Derive /24 provider-network prefixes and collect /32 host routes, then
  # inject them onto fabric chain P2P interfaces so selectors can reach the
  # provider handoff network through the provider-handoff access nodes.
  #
  # Per URS L229: "the reference SAT lab shall realize upstream-emulation cases
  # with VLAN 11 through VLAN 20 as ISP-emulation handoff networks using the
  # TEST-NET-3 documentation IPv4 range, 203.0.113.0/24."
  addProviderSubnetFabricRoutes =
    rtAttrs:
    let
      # Collect provider network prefixes from all services that have
      # providerAddress / customerAddress handoff fields.
      providerSubnetSet =
        builtins.foldl'
          (acc: targetName:
            let
              target = rtAttrs.${targetName} or { };
              services = target.services or { };
              # Scan every service on this target for handoff addresses.
              # A service may expose providerAddress directly or via a
              # server/client sub-record (e.g. pppoe.server.providerAddress).
              scanService = svcAcc: svcName:
                let
                  svc = services.${svcName} or { };
                  server = svc.server or { };
                  client = svc.client or { };
                  providerAddr =
                    svc.providerAddress or server.providerAddress or "";
                  customerAddr =
                    svc.customerAddress or server.customerAddress or client.customerAddress or "";
                  deriveProviderSubnet = addr:
                    let
                      octets = lib.splitString "." addr;
                    in
                    if builtins.length octets >= 3 then
                      let
                        network = "${builtins.elemAt octets 0}.${builtins.elemAt octets 1}.${builtins.elemAt octets 2}.0/24";
                      in
                      svcAcc // { ${network} = true; }
                    else
                      svcAcc;
                  accWithProvider =
                    if providerAddr != "" then deriveProviderSubnet providerAddr else svcAcc;
                in
                if customerAddr != "" then deriveProviderSubnet customerAddr else accWithProvider;
            in
            builtins.foldl' scanService acc (builtins.attrNames services))
          { }
          (builtins.attrNames rtAttrs);
      providerSubnets = builtins.attrNames providerSubnetSet;
      # Also collect /32 host routes for provider and customer addresses
      providerHostSet =
        builtins.foldl'
          (acc: targetName:
            let
              target = rtAttrs.${targetName} or { };
              services = target.services or { };
              scanService = svcAcc: svcName:
                let
                  svc = services.${svcName} or { };
                  server = svc.server or { };
                  client = svc.client or { };
                  providerAddr =
                    svc.providerAddress or server.providerAddress or "";
                  customerAddr =
                    svc.customerAddress or server.customerAddress or client.customerAddress or "";
                  accWithProvider =
                    if providerAddr != "" then svcAcc // { "${providerAddr}/32" = true; } else svcAcc;
                in
                if customerAddr != "" then accWithProvider // { "${customerAddr}/32" = true; } else accWithProvider;
            in
            builtins.foldl' scanService acc (builtins.attrNames services))
          { }
          (builtins.attrNames rtAttrs);
      providerHosts = builtins.attrNames providerHostSet;
      allProviderPrefixes = providerSubnets ++ providerHosts;
    in
    if allProviderPrefixes == [ ] then
      rtAttrs
    else
    let
      fabricRoles = [ "downstream-selector" "policy" "upstream-selector" ];
      peer4For = addr:
        let
          parts = lib.splitString "/" addr;
          addrStr = if builtins.length parts >= 1 then builtins.elemAt parts 0 else "";
          octets = lib.splitString "." addrStr;
        in
        if builtins.length octets != 4 then null
        else
          let
            lastOctet = builtins.elemAt octets 3;
            lastInt = lib.toInt (if lastOctet == "" then "0" else lastOctet);
            peerInt = if lib.mod lastInt 2 == 0 then lastInt + 1 else lastInt - 1;
            peerOctets = builtins.genList
              (i: if i == 3 then builtins.toString peerInt else builtins.elemAt octets i)
              4;
          in builtins.concatStringsSep "." peerOctets;
      isFabricP2p = iface:
        (iface.sourceKind or "") == "p2p"
        && ((iface.backingRef or {}).lane or {}).uplink or "" != "wan";
      providerRoutesFor = peer4:
        builtins.map
          (prefix: {
            dst = prefix;
            proto = "provider";
            via4 = peer4;
            intent = {
              kind = "provider-reachability";
              source = "provider-network";
            };
          })
          allProviderPrefixes;
      augmentTarget = targetName: target:
        let
          role = target.role or "";
          interfaces = (target.effectiveRuntimeRealization or {}).interfaces or {};
        in
        if !(builtins.elem role fabricRoles) then
          target
        else
          let
            updatedInterfaces =
              builtins.mapAttrs
                (ifName: iface:
                  if !(isFabricP2p iface) then
                    iface
                  else
                    let
                      peer4 = peer4For (iface.addr4 or "");
                      routes = iface.routes or {};
                      newRoutes = if peer4 == null then [] else providerRoutesFor peer4;
                      ipv4 = (routes.ipv4 or []) ++ newRoutes;
                      ipv6 = routes.ipv6 or [];
                    in
                    iface // { routes = routes // { inherit ipv4 ipv6; }; }
                )
                interfaces;
          in
          target // {
            effectiveRuntimeRealization =
              (target.effectiveRuntimeRealization or {}) // {
                interfaces = updatedInterfaces;
              };
          };
    in
    builtins.mapAttrs augmentTarget rtAttrs;

  # Apply provider subnet routes BEFORE core tenant return routes so both
  # augmentations compose correctly.
  runtimeTargetsWithProvider = addProviderSubnetFabricRoutes runtimeTargetsWithIntent;

  runtimeTargets =
    builtins.mapAttrs
      (_targetName: normalizeRuntimeTargetRoutesAfterPolicyComplements)
      (addCoreTenantReturnRoutes runtimeTargetsWithProvider);

in
{
  inherit
    accessAdvertisements
    firewallIntent
    policyEndpointBindings
    resolvedServices
    runtimeTargets
    ;
}
