{
  lib,
  helpers,
  dnsPolicy,
  sitePath,
  allowedRelations,
  serviceDefinitions,
}:

let
  inherit (helpers) hasAttr requireStringList sortedNames;
  inherit (dnsPolicy)
    consumerInterfaceCidrsForTenant
    effectiveTrafficTypeForRelation
    optionalProviderAddressesForDnsService
    providerAddressesForDnsService
    providerTenantsForServiceProvider
    relationEndpointMatchesTenant
    tenantNamesForRelationEndpoint
    tenantPrefixesForName
    ;
  uniqueStrings = list: builtins.attrNames (builtins.listToAttrs (map (value: { name = value; value = true; }) list));

  allowedDnsRelation =
    relation:
    let
      relationAttrs = if builtins.isAttrs relation then relation else { };
      serviceName = if builtins.isAttrs (relationAttrs.to or null) && builtins.isString (relationAttrs.to.name or null) then relationAttrs.to.name else null;
      serviceDef = if serviceName != null && hasAttr serviceName serviceDefinitions then serviceDefinitions.${serviceName} else { };
    in
    (relationAttrs.action or "allow") == "allow"
    && builtins.isAttrs (relationAttrs.to or null)
    && (relationAttrs.to.kind or null) == "service"
    && serviceName != null
    && hasAttr serviceName serviceDefinitions
    && effectiveTrafficTypeForRelation relationAttrs serviceDef == "dns";

  dnsRelations = builtins.filter allowedDnsRelation allowedRelations;

  dnsExternalUplinksForEndpoint =
    endpoint:
    uniqueStrings (
      lib.concatMap
        (relation:
          let
            relationAttrs = if builtins.isAttrs relation then relation else { };
            to = if builtins.isAttrs (relationAttrs.to or null) then relationAttrs.to else { };
            uplinks =
              if builtins.isList (to.uplinks or null) then
                requireStringList "${sitePath}.communicationContract.allowedRelations[*].to.uplinks" to.uplinks
              else if builtins.isString (to.name or null) && to.name != "" then
                [ to.name ]
              else
                [ ];
          in
          if
            (relationAttrs.action or "allow") == "allow"
            && (to.kind or null) == "external"
            && effectiveTrafficTypeForRelation relationAttrs { trafficType = "dns"; } == "dns"
            && relationAttrs.from == endpoint
          then
            uplinks
          else
            [ ])
        allowedRelations
    );

  providersForService =
    serviceName:
    let
      serviceDef = serviceDefinitions.${serviceName};
    in
    if builtins.isList (serviceDef.providers or null) then
      requireStringList "${sitePath}.communicationContract.services.${serviceName}.providers" serviceDef.providers
    else
      [ ];

  familyPrefixes =
    family: prefixes:
    builtins.filter
      (prefix:
        if family == 4 then
          builtins.match ".*:.*" prefix == null
        else
          builtins.match ".*:.*" prefix != null)
      prefixes;

  dnsServiceRouteSpecs =
    builtins.map
      (relation:
        let
          relationAttrs = if builtins.isAttrs relation then relation else { };
          serviceName = relationAttrs.to.name or null;
          providers = providersForService serviceName;
          providerTenants = uniqueStrings (lib.concatMap providerTenantsForServiceProvider providers);
          providerPrefixes = uniqueStrings (lib.concatMap tenantPrefixesForName providerTenants);
          providerAddresses = uniqueStrings (lib.concatMap optionalProviderAddressesForDnsService providers);
          consumerTenants = tenantNamesForRelationEndpoint (relationAttrs.from or null);
          consumerPrefixes = uniqueStrings (lib.concatMap tenantPrefixesForName consumerTenants);
        in
        {
          inherit serviceName;
          consumerPrefixes4 = familyPrefixes 4 consumerPrefixes;
          consumerPrefixes6 = familyPrefixes 6 consumerPrefixes;
          providerPrefixes4 = familyPrefixes 4 providerPrefixes;
          providerPrefixes6 = familyPrefixes 6 providerPrefixes;
          providerAddresses4 = familyPrefixes 4 providerAddresses;
          providerAddresses6 = familyPrefixes 6 providerAddresses;
          preferredUplinks = dnsExternalUplinksForEndpoint (relationAttrs.from or null);
        })
      dnsRelations;
in
{
  inherit dnsServiceRouteSpecs;

  policyDerivedDnsForwardersForTenants =
    tenantNames:
    uniqueStrings (
      lib.concatMap
        (tenantName:
          let
            allowedDnsServices =
              uniqueStrings (
                builtins.map
                  (relation:
                    let
                      serviceName = relation.to.name or null;
                    in
                    serviceName)
                  (builtins.filter (relation: relationEndpointMatchesTenant tenantName (relation.from or null)) dnsRelations)
              );
          in
          lib.concatMap (serviceName: lib.concatMap providerAddressesForDnsService (providersForService serviceName)) allowedDnsServices)
        tenantNames
    );

  policyDerivedDnsAllowFromForListeners =
    listenAddrs:
    let
      listenSet = uniqueStrings listenAddrs;
      hostedDnsServices =
        builtins.filter
          (serviceName:
            let
              serviceDef = serviceDefinitions.${serviceName};
              providerAddresses = lib.concatMap providerAddressesForDnsService (providersForService serviceName);
            in
            (serviceDef.trafficType or null) == "dns" && lib.any (addr: builtins.elem addr listenSet) providerAddresses)
          (sortedNames serviceDefinitions);
    in
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
        hostedDnsServices
    );
}
