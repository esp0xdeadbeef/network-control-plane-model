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
, emulationSubnets ? [ ]
,
}:

let
  inherit (common) uniqueStrings;

  resolvedAccessAdvertisements =
    resolveAccessAdvertisements {
      inherit sitePath siteAttrs realizationIndex endpointInventoryIndex routedPrefixesByTenant;
      runtimeTargets = normalizedRuntimeTargets;
    };

  bindAccessRaPathMtu = import ../../ControlModule/runtime-targets/access-ra-path-mtu.nix {
    inherit lib;
  };

  accessAdvertisements = (bindAccessRaPathMtu normalizedRuntimeTargets).bindAdvertisements resolvedAccessAdvertisements;

  policyEndpointBindings =
    resolvePolicyEndpointBindings {
      inherit sitePath siteAttrs attachments domains;
      runtimeTargets = normalizedRuntimeTargets;
    };

  dnsServiceUplinks = import ../../ControlModule/dns-policy/service-uplinks.nix {
    inherit lib uniqueStrings dnsServiceRouteSpecs;
    allowedRelations = (siteAttrs.communicationContract or { }).allowedRelations or [ ];
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
    runtimeTargets = normalizedRuntimeTargets;
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
      inherit sitePath siteAttrs policyEndpointBindings routedPrefixesByTenant;
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

  addPublicIngressRoutes = import ../../ControlModule/runtime-targets/public-ingress-routes.nix {
    inherit lib common;
  };

  runtimeTargetsWithPublicIngressRoutes = addPublicIngressRoutes runtimeTargetsWithIntent;

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

  # ── Emulation subnet route injection ──
  # Per SMS-012: "CPM shall generate selector routes, nftables allow rules, and
  # policy-routing lane entries for emulation subnets using the same fabric-chain
  # path as tenant/transit subnets."
  #
  # Emulation subnets come from HAT inventory emulation declarations and are
  # explicitly marked as non-production. URS L231 authorizes "explicit lab
  # realization" for ISP-emulation address ranges.
  addEmulationSubnetFabricRoutes =
    rtAttrs:
    if emulationSubnets == [ ] then
      rtAttrs
    else
    let
      fabricRoles = [ "downstream-selector" "policy" "upstream-selector" ];
      # Compute peer IPv4 address from a /31 interface address.
      peer4For = addr4:
        let
          octets = lib.splitString "." (builtins.head (lib.splitString "/" addr4));
          addr = builtins.map (builtins.fromJSON) octets;
        in
        if builtins.length addr != 4 then null
        else
          let
            lastOctet = builtins.elemAt addr 3;
            peerLast = if lib.mod lastOctet 2 == 0 then lastOctet + 1 else lastOctet - 1;
          in
          "${builtins.elemAt addr 0}.${builtins.elemAt addr 1}.${builtins.elemAt addr 2}.${builtins.toString peerLast}";
      isFabricP2p = iface:
        (iface.sourceKind or "") == "p2p"
        && ((iface.backingRef or {}).lane or {}).uplink or "" != "wan";
      emulationRoutesFor = peer4:
        builtins.map
          (subnet: {
            dst = subnet;
            proto = "emulation";
            via4 = peer4;
            intent = {
              kind = "emulation-reachability";
              source = "hat-emulation-subnet";
            };
            emulationSubnet = true;
          })
          emulationSubnets;
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
                      newRoutes = if peer4 == null then [] else emulationRoutesFor peer4;
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
      # IPv6: collect provider IPv6 prefixes from providerAddress6 / customerAddress6
      providerSubnetSet6 =
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
                  providerAddr6 =
                    svc.providerAddress6 or server.providerAddress6 or "";
                  customerAddr6 =
                    svc.customerAddress6 or server.customerAddress6 or client.customerAddress6 or "";
                  deriveProviderSubnet6 = addr:
                    let
                      parsed = ipam.splitCIDR addr;
                      addr6Parsed = if parsed != null then ipam.parseIPv6 parsed.addr else null;
                    in
                    if addr6Parsed == null then svcAcc
                    else
                      let
                        networkHextets = builtins.genList
                          (i: if i < 4 then builtins.elemAt addr6Parsed i else 0)
                          8;
                        network = "${ipam.renderIPv6 networkHextets}/64";
                      in svcAcc // { ${network} = true; };
                  accWithProvider6 =
                    if providerAddr6 != "" then deriveProviderSubnet6 providerAddr6 else svcAcc;
                in
                if customerAddr6 != "" then deriveProviderSubnet6 customerAddr6 else accWithProvider6;
            in
            builtins.foldl' scanService acc (builtins.attrNames services))
          { }
          (builtins.attrNames rtAttrs);
      providerSubnets6 = builtins.attrNames providerSubnetSet6;
      providerHostSet6 =
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
                  providerAddr6 =
                    svc.providerAddress6 or server.providerAddress6 or "";
                  customerAddr6 =
                    svc.customerAddress6 or server.customerAddress6 or client.customerAddress6 or "";
                  # Normalize to /128 host route
                  normalize6 = addr:
                    if addr == "" then ""
                    else
                      let
                        parsed = ipam.splitCIDR addr;
                      in
                      if parsed == null then "${addr}/128"
                      else "${parsed.addr}/128";
                  accWithProvider6 =
                    if providerAddr6 != "" then svcAcc // { "${normalize6 providerAddr6}" = true; } else svcAcc;
                in
                if customerAddr6 != "" then accWithProvider6 // { "${normalize6 customerAddr6}" = true; } else accWithProvider6;
            in
            builtins.foldl' scanService acc (builtins.attrNames services))
          { }
          (builtins.attrNames rtAttrs);
      providerHosts6 = builtins.attrNames providerHostSet6;
      allProviderPrefixes6 = providerSubnets6 ++ providerHosts6;
    in
    if allProviderPrefixes == [ ] && allProviderPrefixes6 == [ ] then
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
      peer6For = addr:
        let
          parsed = ipam.splitCIDR addr;
          addrParsed = if parsed != null then ipam.parseIPv6 parsed.addr else null;
        in
        if addrParsed == null then null
        else
          let
            peerHextets = builtins.genList
              (idx:
                if idx == 7 then
                  if lib.mod (builtins.elemAt addrParsed 7) 2 == 0 then
                    (builtins.elemAt addrParsed 7) + 1
                  else
                    (builtins.elemAt addrParsed 7) - 1
                else
                  builtins.elemAt addrParsed idx
              )
              8;
          in ipam.renderIPv6 peerHextets;
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
      providerRoutesFor6 = peer6:
        builtins.map
          (prefix: {
            dst = prefix;
            proto = "provider";
            via6 = peer6;
            intent = {
              kind = "provider-reachability";
              source = "provider-network";
            };
          })
          allProviderPrefixes6;
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
                      peer6 = peer6For (iface.addr6 or "");
                      routes = iface.routes or {};
                      newRoutes4 = if peer4 == null then [] else providerRoutesFor peer4;
                      newRoutes6 = if peer6 == null then [] else providerRoutesFor6 peer6;
                      ipv4 = (routes.ipv4 or []) ++ newRoutes4;
                      ipv6 = (routes.ipv6 or []) ++ newRoutes6;
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

  # Apply emulation subnet routes AND provider subnet routes BEFORE core tenant
  # return routes so all augmentations compose correctly.
  runtimeTargetsWithEmulation = addEmulationSubnetFabricRoutes runtimeTargetsWithPublicIngressRoutes;
  runtimeTargetsWithProvider = addProviderSubnetFabricRoutes runtimeTargetsWithEmulation;

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
