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

  runtimeTargets =
    builtins.mapAttrs
      (_targetName: normalizeRuntimeTargetRoutesAfterPolicyComplements)
      (addCoreTenantReturnRoutes runtimeTargetsWithIntent);

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
