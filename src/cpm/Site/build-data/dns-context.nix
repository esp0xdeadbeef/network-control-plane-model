{
  lib,
  helpers,
  common,
  inventoryEndpoints,
  sitePath,
  domains,
  attachments,
  nodes,
  ownership,
  allowedRelations,
  serviceDefinitions,
}:

let
  dnsPolicy = import ../../ControlModule/dns-policy {
    inherit
      lib
      helpers
      common
      inventoryEndpoints
      sitePath
      domains
      attachments
      nodes
      ownership
      allowedRelations
      serviceDefinitions
      ;
  };

  dnsPolicyDerived = import ../../ControlModule/dns-policy/derived-services.nix {
    inherit lib helpers dnsPolicy sitePath allowedRelations serviceDefinitions;
  };

in
{
  inherit (dnsPolicy)
    providerEndpointForServiceProvider
    providerTenantsForServiceProvider
    ;
  inherit (dnsPolicyDerived)
    dnsServiceRouteSpecs
    policyDerivedDnsAllowFromForListeners
    policyDerivedDnsAllowedClassesForListeners
    policyDerivedDnsAllowedClassesForTenants
    policyDerivedDnsDirectEgressBlockedForListeners
    policyDerivedDnsDirectEgressBlockedForTenants
    policyDerivedDnsForwardersForTenants
    ;
}
