{
  lib,
  helpers,
  dnsPolicy,
  sitePath,
  allowedRelations,
  serviceDefinitions,
  dnsRelations,
  providersForService,
}:

let
  inherit (helpers) requireStringList;
  inherit (dnsPolicy)
    effectiveTrafficTypeForRelation
    optionalProviderAddressesForDnsService
    providerTenantsForServiceProvider
    tenantNamesForRelationEndpoint
    tenantPrefixesForName
    ;

  endpointKeys = import ./endpoint-keys.nix { };
  inherit (endpointKeys) endpointKey;

  uniqueStrings =
    list:
    builtins.attrNames (
      builtins.listToAttrs (map (value: { name = value; value = true; }) list)
    );

  dnsExternalUplinksForEndpoint =
    endpoint: trafficType:
    let
      expectedEndpointKey = endpointKey endpoint;
    in
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
            && effectiveTrafficTypeForRelation relationAttrs { inherit trafficType; } == trafficType
            && endpointKey (relationAttrs.from or null) == expectedEndpointKey
          then
            uplinks
          else
            [ ])
        allowedRelations
    );

  familyPrefixes =
    family: prefixes:
    builtins.filter
      (prefix:
        if family == 4 then
          builtins.match ".*:.*" prefix == null
        else
          builtins.match ".*:.*" prefix != null)
      prefixes;
in
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
      relationTrafficType = effectiveTrafficTypeForRelation relationAttrs { trafficType = "dns"; };
    in
    {
      inherit serviceName;
      consumerPrefixes4 = familyPrefixes 4 consumerPrefixes;
      consumerPrefixes6 = familyPrefixes 6 consumerPrefixes;
      providerPrefixes4 = familyPrefixes 4 providerPrefixes;
      providerPrefixes6 = familyPrefixes 6 providerPrefixes;
      providerAddresses4 = familyPrefixes 4 providerAddresses;
      providerAddresses6 = familyPrefixes 6 providerAddresses;
      preferredUplinks = dnsExternalUplinksForEndpoint (relationAttrs.from or null) relationTrafficType;
    })
  dnsRelations
