{
  lib,
  helpers,
  dnsPolicy,
  sitePath,
  allowedRelations,
  serviceDefinitions,
}:

let
  context = import ./derived-services/context.nix {
    inherit lib helpers dnsPolicy sitePath allowedRelations serviceDefinitions;
  };

  inherit (context) dnsRelations providersForService;

  dnsServiceRouteSpecs = import ./service-route-specs.nix {
    inherit
      lib
      helpers
      dnsPolicy
      sitePath
      allowedRelations
      serviceDefinitions
      dnsRelations
      providersForService
      ;
  };

  allowedClasses = import ./allowed-classes.nix {
    inherit lib allowedRelations dnsPolicy providersForService serviceDefinitions;
  };

  forwarders = import ./derived-services/forwarders.nix {
    inherit lib dnsPolicy serviceDefinitions context;
  };

  directEgress = import ./derived-services/direct-egress.nix {
    inherit lib dnsPolicy context;
  };
in
{
  inherit dnsServiceRouteSpecs;

  policyDerivedDnsForwardersForTenants = forwarders.forTenants;
  policyDerivedDnsAllowFromForListeners = forwarders.allowFromForListeners;
  policyDerivedDnsAllowedClassesForTenants = allowedClasses.forTenants;
  policyDerivedDnsAllowedClassesForListeners = allowedClasses.forListeners;
  policyDerivedDnsDirectEgressBlockedForTenants = directEgress.blockedForTenants;
  policyDerivedDnsDirectEgressBlockedForListeners = directEgress.blockedForListeners;
}
