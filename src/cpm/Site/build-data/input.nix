{
  helpers,
  common,
  inventory,
  site,
  sitePath,
}:

let
  inherit (helpers)
    requireAttrs
    requireList
    requireString
    requireStringList
    ;
  inherit (common) attrsOrEmpty;

  siteAttrs = requireAttrs sitePath site;
  ownership = attrsOrEmpty (siteAttrs.ownership or null);

  siteId = requireString "${sitePath}.siteId" (siteAttrs.siteId or null);
  siteDisplayName = requireString "${sitePath}.siteName" (siteAttrs.siteName or null);
  policyNodeName = requireString "${sitePath}.policyNodeName" (siteAttrs.policyNodeName or null);
  upstreamSelectorNodeName = requireString "${sitePath}.upstreamSelectorNodeName" (siteAttrs.upstreamSelectorNodeName or null);
  coreNodeNames = requireStringList "${sitePath}.coreNodeNames" (siteAttrs.coreNodeNames or null);
  uplinkCoreNames = requireStringList "${sitePath}.uplinkCoreNames" (siteAttrs.uplinkCoreNames or null);
  uplinkNames = requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);

  attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);
  links = requireAttrs "${sitePath}.links" (siteAttrs.links or null);
  nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);
  transitAttrs = requireAttrs "${sitePath}.transit" (siteAttrs.transit or null);

  domainsValue = requireAttrs "${sitePath}.domains" (siteAttrs.domains or null);
  domains = {
    tenants = requireList "${sitePath}.domains.tenants" (domainsValue.tenants or null);
    externals = requireList "${sitePath}.domains.externals" (domainsValue.externals or null);
  };

  tenantPrefixOwners = requireAttrs "${sitePath}.tenantPrefixOwners" (siteAttrs.tenantPrefixOwners or null);

  communicationContract =
    if builtins.isAttrs (siteAttrs.communicationContract or null) then
      let
        contract = requireAttrs "${sitePath}.communicationContract" siteAttrs.communicationContract;
        canonicalRelations =
          if builtins.isList (contract.relations or null) then
            { relations = requireList "${sitePath}.communicationContract.relations" contract.relations; }
          else if builtins.isList (contract.allowedRelations or null) then
            { allowedRelations = requireList "${sitePath}.communicationContract.allowedRelations" contract.allowedRelations; }
          else
            { };
      in
      canonicalRelations
      // (if builtins.isList (contract.services or null) then { services = contract.services; } else { })
      // (if builtins.isList (contract.trafficTypes or null) then { trafficTypes = contract.trafficTypes; } else { })
    else
      null;

  policyAttrs =
    if builtins.isAttrs (siteAttrs.policy or null) then requireAttrs "${sitePath}.policy" siteAttrs.policy else { };

  inventoryAttrs = attrsOrEmpty inventory;
  inventoryEndpoints = attrsOrEmpty (inventoryAttrs.endpoints or null);

  serviceDefinitions =
    if communicationContract != null && builtins.isList (communicationContract.services or null) then
      builtins.listToAttrs (
        builtins.genList
          (idx:
            let
              servicePath = "${sitePath}.communicationContract.services[${toString idx}]";
              service = requireAttrs servicePath (builtins.elemAt communicationContract.services idx);
              serviceName = requireString "${servicePath}.name" (service.name or null);
            in
            { name = serviceName; value = service; })
          (builtins.length communicationContract.services)
      )
    else
      { };

  allowedRelations =
    if communicationContract != null && builtins.isList (communicationContract.relations or null) then
      communicationContract.relations
    else if communicationContract != null && builtins.isList (communicationContract.allowedRelations or null) then
      communicationContract.allowedRelations
    else
      [ ];

in
{
  inherit
    allowedRelations
    attachments
    communicationContract
    coreNodeNames
    domains
    domainsValue
    inventoryAttrs
    inventoryEndpoints
    links
    nodes
    ownership
    policyAttrs
    policyNodeName
    serviceDefinitions
    siteAttrs
    siteDisplayName
    siteId
    tenantPrefixOwners
    transitAttrs
    uplinkCoreNames
    uplinkNames
    upstreamSelectorNodeName
    ;
}
