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
, normalizeRuntimeTargetRoutes
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

  runtimeTargets = builtins.mapAttrs (_targetName: normalizeRuntimeTargetRoutes) runtimeTargetsWithIntent;

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
