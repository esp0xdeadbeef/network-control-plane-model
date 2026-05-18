{ lib, dnsPolicy, serviceDefinitions, context }:

let
  inherit (dnsPolicy)
    consumerInterfaceCidrsForTenant
    providerAddressesForDnsService
    relationEndpointMatchesTenant
    tenantNamesForRelationEndpoint
    tenantPrefixesForName
    ;
  inherit (context)
    dnsRelations
    hostedDnsServicesForListeners
    providersForService
    uniqueStrings
    ;
in
{
  forTenants = tenantNames:
    uniqueStrings (
      lib.concatMap
        (tenantName:
          let
            allowedDnsServices =
              uniqueStrings (
                builtins.map
                  (relation: relation.to.name or null)
                  (builtins.filter (relation: relationEndpointMatchesTenant tenantName (relation.from or null)) dnsRelations)
              );
          in
          lib.concatMap (serviceName: lib.concatMap providerAddressesForDnsService (providersForService serviceName)) allowedDnsServices)
        tenantNames
    );

  allowFromForListeners = listenAddrs:
    uniqueStrings (
      lib.concatMap
        (serviceName:
          lib.concatMap
            (relation:
              let
                relationAttrs = if builtins.isAttrs relation then relation else { };
                relationServiceName =
                  if builtins.isAttrs (relationAttrs.to or null) && builtins.isString (relationAttrs.to.name or null) then
                    relationAttrs.to.name
                  else
                    null;
              in
              if relationServiceName == serviceName then
                lib.concatMap
                  (tenantName: (tenantPrefixesForName tenantName) ++ (consumerInterfaceCidrsForTenant tenantName))
                  (tenantNamesForRelationEndpoint (relationAttrs.from or null))
              else
                [ ])
            dnsRelations)
        (hostedDnsServicesForListeners listenAddrs)
    );
}
