{ helpers, bindingCommon }:

{ sitePath, siteAttrs, domains }:

let
  inherit (helpers) ensureUniqueEntries requireAttrs requireString requireStringList;
  inherit (bindingCommon) attrsOrEmpty listOrEmpty uniqueStrings makeStringSet;

  communicationContract = attrsOrEmpty (siteAttrs.communicationContract or null);
  relations =
    if builtins.isList (communicationContract.relations or null) then
      communicationContract.relations
    else
      listOrEmpty (communicationContract.allowedRelations or null);

  serviceDefinitions =
    ensureUniqueEntries
      "${sitePath}.communicationContract.services"
      (
        let services = listOrEmpty (communicationContract.services or null);
        in
        builtins.genList
          (idx:
            let
              servicePath = "${sitePath}.communicationContract.services[${toString idx}]";
              service = requireAttrs servicePath (builtins.elemAt services idx);
              serviceName = requireString "${servicePath}.name" (service.name or null);
            in
            { name = serviceName; value = service; })
          (builtins.length services)
      );

  siteUplinkNames = requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);

  declaredExternalNames =
    map
      (external:
        let externalAttrs = requireAttrs "${sitePath}.domains.externals[*]" external;
        in requireString "${sitePath}.domains.externals[*].name" (externalAttrs.name or null))
      domains.externals;

  collectEndpointNames = expectedKind: endpointRaw:
    let
      endpoint = attrsOrEmpty endpointRaw;
      kind = endpoint.kind or null;
    in
    if kind != expectedKind then
      [ ]
    else if expectedKind == "tenant" then
      builtins.filter helpers.isNonEmptyString [ endpoint.name or null ]
    else if expectedKind == "tenant-set" then
      builtins.filter helpers.isNonEmptyString (listOrEmpty (endpoint.members or null))
    else if expectedKind == "external" then
      if helpers.isNonEmptyString (endpoint.name or null) then [ endpoint.name ] else builtins.filter helpers.isNonEmptyString (listOrEmpty (endpoint.uplinks or null))
    else if expectedKind == "service" then
      builtins.filter helpers.isNonEmptyString [ endpoint.name or null ]
    else
      [ ];

  relationNames = expectedKind:
    builtins.concatLists (
      builtins.genList
        (idx:
          let relation = attrsOrEmpty (builtins.elemAt relations idx);
          in collectEndpointNames expectedKind (relation.from or null) ++ collectEndpointNames expectedKind (relation.to or null))
        (builtins.length relations)
    );

  requiredRelationNames = expectedKind:
    builtins.concatLists (
      builtins.genList
        (idx:
          let relation = attrsOrEmpty (builtins.elemAt relations idx);
          in
          if (relation.action or "allow") == "deny" then
            [ ]
          else
            collectEndpointNames expectedKind (relation.from or null)
            ++ collectEndpointNames expectedKind (relation.to or null))
        (builtins.length relations)
    );

  relationTenantNames =
    relationNames "tenant" ++ relationNames "tenant-set";
  relationExternalNames = relationNames "external";
  relationServiceNames = relationNames "service";
  relationRequiredTenantNames =
    requiredRelationNames "tenant" ++ requiredRelationNames "tenant-set";
  relationRequiredExternalNames = requiredRelationNames "external";

in
{
  inherit relations serviceDefinitions siteUplinkNames declaredExternalNames;
  inherit relationTenantNames relationExternalNames;
  relationTenantSet = makeStringSet relationTenantNames;
  relationExternalSet = makeStringSet relationExternalNames;
  relationRequiredTenantSet = makeStringSet relationRequiredTenantNames;
  relationRequiredExternalSet = makeStringSet relationRequiredExternalNames;
  serviceNamesFromContract = uniqueStrings ((helpers.sortedNames serviceDefinitions) ++ relationServiceNames);
}
