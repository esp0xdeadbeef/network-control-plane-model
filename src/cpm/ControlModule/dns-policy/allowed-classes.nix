{
  lib,
  allowedRelations,
  dnsPolicy,
  providersForService,
  serviceDefinitions,
}:

let
  inherit (dnsPolicy)
    providerAddressesForDnsService
    relationEndpointMatchesTenant
    ;

  uniqueStrings = list: builtins.attrNames (builtins.listToAttrs (map (value: { name = value; value = true; }) list));

  dnsExternalRelation =
    relation:
    let
      relationAttrs = if builtins.isAttrs relation then relation else { };
    in
    (relationAttrs.action or "allow") == "allow"
    && (relationAttrs.trafficType or null) == "dns"
    && builtins.isAttrs (relationAttrs.to or null)
    && (relationAttrs.to.kind or null) == "external";

  dnsExternalRelations = builtins.filter dnsExternalRelation allowedRelations;

  hostedDnsServicesForListeners =
    listenAddrs:
    let
      listenSet = uniqueStrings listenAddrs;
    in
    builtins.filter
      (serviceName:
        let
          serviceDef = serviceDefinitions.${serviceName};
          providerAddresses = lib.concatMap providerAddressesForDnsService (providersForService serviceName);
        in
        (serviceDef.trafficType or null) == "dns" && lib.any (addr: builtins.elem addr listenSet) providerAddresses)
      (builtins.attrNames serviceDefinitions);
in
{
  forTenants =
    tenantNames:
    let
      hasTenantExternalDns =
        builtins.any
          (relation:
            builtins.any
              (tenantName: relationEndpointMatchesTenant tenantName (relation.from or null))
              tenantNames)
          dnsExternalRelations;
    in
    if hasTenantExternalDns then [ "explicit-egress-default" ] else [ ];

  forListeners =
    listenAddrs:
    let
      hostedDnsServices = hostedDnsServicesForListeners listenAddrs;
      hasHostedExternalDns =
        builtins.any
          (relation:
            builtins.isAttrs (relation.from or null)
            && (relation.from.kind or null) == "service"
            && builtins.elem (relation.from.name or "") hostedDnsServices)
          dnsExternalRelations;
    in
    if hasHostedExternalDns then [ "explicit-egress-default" ] else [ ];
}
