{ common }:

{
  endpointBindings,
  services ? [ ],
  transitInterfaces,
}:

let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];
  uniqueStrings =
    values:
    builtins.attrNames (
      builtins.listToAttrs (
        map (value: {
          name = value;
          value = true;
        }) (builtins.filter (value: builtins.isString value && value != "") values)
      )
    );

  serviceRecords = builtins.listToAttrs (
    map
      (service: {
        name = service.name;
        value = service;
      })
      (
        builtins.filter (
          service: builtins.isAttrs service && builtins.isString (service.name or null) && service.name != ""
        ) (listOrEmpty services)
      )
  );

  tenantBindings = attrsOrEmpty (endpointBindings.tenants or null);
  externalBindings = attrsOrEmpty (endpointBindings.externals or null);
  serviceBindings = attrsOrEmpty (endpointBindings.services or null);

  accessNodesForTenant =
    tenantName:
    if !builtins.hasAttr tenantName tenantBindings then
      [ ]
    else
      uniqueStrings (
        map (binding: (attrsOrEmpty binding).logicalNode or null) (
          listOrEmpty (tenantBindings.${tenantName}.runtimeBindings or null)
        )
      );

  tenantNamesForLogicalNode =
    logicalNode:
    if !(builtins.isString logicalNode) || logicalNode == "" then
      [ ]
    else
      uniqueStrings (
        builtins.concatLists (
          map (
            tenantName:
            let
              bindings = listOrEmpty (tenantBindings.${tenantName}.runtimeBindings or null);
            in
            if builtins.any (binding: ((attrsOrEmpty binding).logicalNode or null) == logicalNode) bindings then
              [ tenantName ]
            else
              [ ]
          ) (builtins.attrNames tenantBindings)
        )
      );

  accessNodesForLogicalNodeTenantAttachment =
    logicalNode:
    uniqueStrings (
      builtins.concatLists (map accessNodesForTenant (tenantNamesForLogicalNode logicalNode))
    );

  runtimeLogicalNodesForExternal =
    externalName:
    if
      !(builtins.isString externalName)
      || externalName == ""
      || !(builtins.hasAttr externalName externalBindings)
    then
      [ ]
    else
      uniqueStrings (
        map (binding: (attrsOrEmpty binding).logicalNode or null) (
          listOrEmpty (externalBindings.${externalName}.runtimeBindings or null)
        )
      );

  namesForEndpoint =
    expectedKind: endpoint:
    let
      ep = attrsOrEmpty endpoint;
    in
    if (ep.kind or null) != expectedKind then
      [ ]
    else if expectedKind == "tenant-set" then
      listOrEmpty (ep.members or null)
    else if builtins.isString (ep.name or null) && ep.name != "" then
      [ ep.name ]
    else if expectedKind == "external" then
      listOrEmpty (ep.uplinks or null)
    else
      [ ];

  serviceProviderTenants =
    endpoint:
    uniqueStrings (
      builtins.concatLists (
        map (
          serviceName:
          if builtins.hasAttr serviceName serviceRecords then
            listOrEmpty (serviceRecords.${serviceName}.providerTenants or null)
          else
            [ ]
        ) (namesForEndpoint "service" endpoint)
      )
    );

in
{
  inherit
    attrsOrEmpty
    listOrEmpty
    uniqueStrings
    serviceRecords
    transitInterfaces
    ;
  accessInterfaces = builtins.filter (
    iface: common.laneKind iface == "access" && common.laneAccess iface != null
  ) transitInterfaces;
  uplinkInterfaces = builtins.filter (
    iface: common.laneKind iface == "access-uplink" && common.laneAccess iface != null
  ) transitInterfaces;
  coreInterfaces = builtins.filter (
    iface: common.uplinks iface != [ ] && common.laneKind iface == "uplink"
  ) transitInterfaces;
  policyInterfaces = builtins.filter (
    iface: common.laneKind iface == "access-uplink" && common.laneUplink iface != null
  ) transitInterfaces;
  externalUplinks =
    externalName:
    if !builtins.hasAttr externalName externalBindings then
      [ ]
    else
      uniqueStrings (
        listOrEmpty (externalBindings.${externalName}.uplinks or null)
        ++ listOrEmpty (externalBindings.${externalName}.overlays or null)
      );
  serviceKnown =
    endpoint:
    builtins.any (
      serviceName:
      builtins.hasAttr serviceName serviceBindings || builtins.hasAttr serviceName serviceRecords
    ) (namesForEndpoint "service" endpoint);
  accessNodesForEndpoint =
    endpoint:
    uniqueStrings (
      builtins.concatLists (
        map accessNodesForTenant (
          namesForEndpoint "tenant" endpoint
          ++ namesForEndpoint "tenant-set" endpoint
          ++ serviceProviderTenants endpoint
        )
      )
    );
  uplinksForEndpoint =
    endpoint:
    uniqueStrings (
      builtins.concatLists (
        map (
          name:
          if !builtins.hasAttr name externalBindings then
            [ ]
          else
            (
              listOrEmpty (externalBindings.${name}.uplinks or null)
              ++ listOrEmpty (externalBindings.${name}.overlays or null)
            )
        ) (namesForEndpoint "external" endpoint)
      )
    );
  serviceAccessNodes =
    endpoint:
    uniqueStrings (builtins.concatLists (map accessNodesForTenant (serviceProviderTenants endpoint)));
  serviceNamesForEndpoint = endpoint: namesForEndpoint "service" endpoint;
  inherit accessNodesForLogicalNodeTenantAttachment runtimeLogicalNodesForExternal;
}
