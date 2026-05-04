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
  inherit (helpers) hasAttr isNonEmptyString requireAttrs requireString requireStringList sortedNames;
  inherit (common) attrsOrEmpty cidrContainsAddress uniqueStrings;
  providerEndpoints = import ./provider-endpoints.nix {
    inherit helpers common inventoryEndpoints;
  };

  relationEndpointMatchesTenant =
    tenantName: endpoint:
    if endpoint == "any" then
      true
    else if builtins.isString endpoint then
      endpoint == tenantName
    else if builtins.isList endpoint then
      lib.any (item: relationEndpointMatchesTenant tenantName item) endpoint
    else if builtins.isAttrs endpoint then
      let
        kind = endpoint.kind or null;
      in
      if kind == "tenant" then (endpoint.name or null) == tenantName
      else if kind == "tenant-set" && builtins.isList (endpoint.members or null) then builtins.elem tenantName endpoint.members
      else false
    else
      false;

  effectiveTrafficTypeForRelation =
    relation: serviceDef:
    let
      relationTrafficType = relation.trafficType or null;
      serviceTrafficType = serviceDef.trafficType or null;
    in
    if isNonEmptyString relationTrafficType then relationTrafficType else serviceTrafficType;

  tenantPrefixesForName =
    tenantName:
    let
      tenantDef = lib.findFirst (tenant: builtins.isAttrs tenant && (tenant.name or null) == tenantName) null domains.tenants;
      tenantPath = "${sitePath}.domains.tenants.${tenantName}";
    in
    if tenantDef == null then [ ] else uniqueStrings (
      lib.optional (isNonEmptyString (tenantDef.ipv4 or null)) (requireString "${tenantPath}.ipv4" tenantDef.ipv4)
      ++ lib.optional (isNonEmptyString (tenantDef.ipv6 or null)) (requireString "${tenantPath}.ipv6" tenantDef.ipv6)
    );

  attachedNodeNamesForTenant =
    tenantName:
    uniqueStrings (
      (builtins.map
        (attachment:
          let
            attachmentAttrs = requireAttrs "${sitePath}.attachments[*]" attachment;
          in
          if (attachmentAttrs.kind or null) == "tenant" && (attachmentAttrs.name or null) == tenantName && isNonEmptyString (attachmentAttrs.unit or null) then
            attachmentAttrs.unit
          else
            "")
        attachments)
      ++ (builtins.map
        (nodeName:
          let
            nodePath = "${sitePath}.nodes.${nodeName}";
            nodeAttrs = requireAttrs nodePath nodes.${nodeName};
            attachedTenants =
              if builtins.isList (nodeAttrs.attachments or null) then
                builtins.map (attachment:
                  let
                    attachmentAttrs = requireAttrs "${nodePath}.attachments[*]" attachment;
                  in
                  if (attachmentAttrs.kind or null) == "tenant" && isNonEmptyString (attachmentAttrs.name or null) then attachmentAttrs.name else "") nodeAttrs.attachments
              else [ ];
          in
          if builtins.elem tenantName attachedTenants then nodeName else "")
        (sortedNames nodes))
    );

  interfaceCidrsForNode =
    nodeName:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath nodes.${nodeName};
      nodeInterfaces = requireAttrs "${nodePath}.interfaces" (nodeAttrs.interfaces or null);
    in
    uniqueStrings (lib.concatMap
      (ifName:
        let
          iface = requireAttrs "${nodePath}.interfaces.${ifName}" nodeInterfaces.${ifName};
        in
        lib.optional (isNonEmptyString (iface.addr4 or null)) (requireString "${nodePath}.interfaces.${ifName}.addr4" iface.addr4)
        ++ lib.optional (isNonEmptyString (iface.addr6 or null)) (requireString "${nodePath}.interfaces.${ifName}.addr6" iface.addr6))
      (sortedNames nodeInterfaces));

  consumerInterfaceCidrsForTenant = tenantName: uniqueStrings (lib.concatMap interfaceCidrsForNode (attachedNodeNamesForTenant tenantName));

  tenantNameForAddress =
    address:
    let
      matchingTenants =
        lib.filter
          (tenant:
            let
              tenantName = requireString "${sitePath}.domains.tenants[*].name" (tenant.name or null);
              tenantPath = "${sitePath}.domains.tenants.${tenantName}";
              prefixes = lib.optional (isNonEmptyString (tenant.ipv4 or null)) (requireString "${tenantPath}.ipv4" tenant.ipv4);
            in
            lib.any (prefix: cidrContainsAddress prefix address) prefixes)
          domains.tenants;
    in
    if builtins.length matchingTenants == 1 then (builtins.head matchingTenants).name else null;

  providerTenantsForServiceProvider =
    providerName:
    let
      ownershipMatches =
        if builtins.isList (ownership.endpoints or null) then
          lib.filter (endpoint: builtins.isAttrs endpoint && (endpoint.name or null) == providerName && isNonEmptyString (endpoint.tenant or null)) ownership.endpoints
        else
          [ ];
      inventoryEndpoint = attrsOrEmpty (inventoryEndpoints.${providerName} or null);
      inventoryAddresses = uniqueStrings (if builtins.isList (inventoryEndpoint.ipv4 or null) then requireStringList "inventory.endpoints.${providerName}.ipv4" inventoryEndpoint.ipv4 else [ ]);
    in
    uniqueStrings ((map (endpoint: endpoint.tenant) ownershipMatches) ++ lib.filter (tenant: tenant != null) (map tenantNameForAddress inventoryAddresses));

  tenantNamesForRelationEndpoint =
    endpoint:
    if endpoint == "any" then builtins.map (tenant: tenant.name) domains.tenants
    else if builtins.isString endpoint then [ endpoint ]
    else if builtins.isList endpoint then uniqueStrings (lib.concatMap tenantNamesForRelationEndpoint endpoint)
    else if builtins.isAttrs endpoint then
      let
        kind = endpoint.kind or null;
      in
      if kind == "tenant" && isNonEmptyString (endpoint.name or null) then [ endpoint.name ]
      else if kind == "tenant-set" && builtins.isList (endpoint.members or null) then requireStringList "${sitePath}.communicationContract.allowedRelations[*].from.members" endpoint.members
      else [ ]
    else [ ];

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
in
{
  inherit (providerEndpoints) optionalProviderAddressesForDnsService providerAddressesForDnsService providerEndpointForServiceProvider;
  inherit consumerInterfaceCidrsForTenant effectiveTrafficTypeForRelation providerTenantsForServiceProvider relationEndpointMatchesTenant;
  inherit tenantNamesForRelationEndpoint tenantPrefixesForName;
  inherit dnsRelations;
}
