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
      # FS-540-HDS-010-SDS-010-SMS-035: fail-closed — never inject public
      # forwarder defaults. When a DNS service has modelled WAN egress but no
      # provider-access upstream record, the intent is incomplete and the CPM
      # must not silently fall back to hard-coded public resolvers. The
      # renderer will emit a reproducibility warning for the empty forwarder
      # list so the operator can fix inventory before traffic leaves the site.
      [ ]
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
