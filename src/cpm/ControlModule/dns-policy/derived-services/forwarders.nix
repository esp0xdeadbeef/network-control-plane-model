{ lib, dnsPolicy, providerAccessDns, serviceDefinitions, context }:

let
  inherit (dnsPolicy)
    consumerInterfaceCidrsForTenant
    optionalProviderAddressesForDnsService
    relationEndpointMatchesTenant
    tenantNamesForRelationEndpoint
    tenantPrefixesForName
    ;
  inherit (context)
    allowedDnsExternalRelations
    dnsRelations
    hostedDnsServicesForListeners
    providersForService
    uniqueStrings
    ;

  defaultPublicForwarders = [
    "1.1.1.1"
    "9.9.9.9"
    "2606:4700:4700::1111"
    "2620:fe::fe"
  ];

  hasServiceExternalDnsEgress = serviceName:
    builtins.any
      (relation:
        builtins.isAttrs (relation.from or null)
        && (relation.from.kind or null) == "service"
        && (relation.from.name or null) == serviceName)
      allowedDnsExternalRelations;

  serviceExternalDnsRelations = serviceName:
    builtins.filter
      (relation:
        builtins.isAttrs (relation.from or null)
        && (relation.from.kind or null) == "service"
        && (relation.from.name or null) == serviceName)
      allowedDnsExternalRelations;

  providerAccessRecordsForHostedServices = hostedDnsServices:
    lib.concatMap
      (serviceName: lib.concatMap providerAccessDns.recordsForRelation (serviceExternalDnsRelations serviceName))
      hostedDnsServices;
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
          lib.concatMap
            (serviceName:
              lib.concatMap (optionalProviderAddressesForDnsService serviceName) (providersForService serviceName))
            allowedDnsServices)
        tenantNames
    );

  forListeners = listenAddrs:
    let
      hostedDnsServices = hostedDnsServicesForListeners listenAddrs;
      providerAccessRecords = providerAccessRecordsForHostedServices hostedDnsServices;
    in
    if providerAccessRecords != [ ] then
      [ ]
    else if builtins.any hasServiceExternalDnsEgress hostedDnsServices then
      defaultPublicForwarders
    else
      [ ];

  upstreamRecordsForListeners = listenAddrs:
    providerAccessRecordsForHostedServices (hostedDnsServicesForListeners listenAddrs);

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
