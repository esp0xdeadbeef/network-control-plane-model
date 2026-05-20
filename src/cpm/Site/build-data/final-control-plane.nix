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

  firewallIntent =
    resolveFirewallIntent {
      services = resolvedServices;
      inherit sitePath siteAttrs policyEndpointBindings;
      runtimeTargets = normalizedRuntimeTargets;
    };

  routeDnsServiceReachability = import ../../ControlModule/runtime-targets/dns-service-routes.nix {
    inherit lib common;
  };

  routeAugmentedRuntimeTargets =
    routeDnsServiceReachability {
      inherit firewallIntent normalizedRuntimeTargets;
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

  runtimeTargets =
    finalizeRuntimeTargets {
      inherit accessAdvertisements firewallIntent;
      normalizedRuntimeTargets = routeAugmentedRuntimeTargets;
    };

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
