{
  lib,
  helpers,
  uniqueStrings,
  policyEndpointBindings,
  providerEndpointForServiceProvider,
  providerTenantsForServiceProvider,
  preferredDnsUplinksByRelationForService,
  preferredDnsUplinksForService,
  sitePath,
}:

let
  inherit (helpers) requireStringList sortedNames;
in
builtins.map
  (
    serviceName:
    let
      resolvedService = policyEndpointBindings.services.${serviceName};
      providerNames =
        if builtins.isList (resolvedService.providers or null) then
          requireStringList "${sitePath}.services.${serviceName}.providers" resolvedService.providers
        else
          [ ];
    in
    resolvedService
    // {
      name = serviceName;
      providerEndpoints = builtins.map providerEndpointForServiceProvider providerNames;
      providerTenants = uniqueStrings (
        lib.concatMap providerTenantsForServiceProvider providerNames
      );
      preferredUplinks = preferredDnsUplinksForService serviceName;
      preferredUplinksByRelation = preferredDnsUplinksByRelationForService serviceName;
    }
  )
  (sortedNames policyEndpointBindings.services)
