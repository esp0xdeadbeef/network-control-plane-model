{ common }:

{ endpointBindings, relations, services ? [ ], transitInterfaces }:
let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];

  uniqueStrings = values:
    builtins.attrNames (
      builtins.listToAttrs (
        builtins.map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter (value: builtins.isString value && value != "") values)
      )
    );

  accessInterfaces =
    builtins.filter
      (iface: common.laneKind iface == "access" && common.laneAccess iface != null)
      transitInterfaces;

  uplinkInterfaces =
    builtins.filter
      (iface: common.laneKind iface == "access-uplink" && common.laneAccess iface != null)
      transitInterfaces;

  tenantBindings = attrsOrEmpty (endpointBindings.tenants or null);
  externalBindings = attrsOrEmpty (endpointBindings.externals or null);
  serviceBindings = attrsOrEmpty (endpointBindings.services or null);
  serviceRecords =
    builtins.listToAttrs (
      builtins.map
        (service: {
          name = service.name;
          value = service;
        })
        (builtins.filter (service: builtins.isAttrs service && builtins.isString (service.name or null) && service.name != "") (listOrEmpty services))
    );

  accessNodesForTenant = tenantName:
    if !builtins.hasAttr tenantName tenantBindings then
      [ ]
    else
      uniqueStrings (
        builtins.map
          (binding: (attrsOrEmpty binding).logicalNode or null)
          (listOrEmpty (tenantBindings.${tenantName}.runtimeBindings or null))
      );

  externalUplinks = externalName:
    if !builtins.hasAttr externalName externalBindings then
      [ ]
    else
      uniqueStrings (
        listOrEmpty (externalBindings.${externalName}.uplinks or null)
        ++ listOrEmpty (externalBindings.${externalName}.overlays or null)
      );

  namesForEndpoint = expectedKind: endpoint:
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
    else if expectedKind == "service" then
      if builtins.isString (ep.name or null) && ep.name != "" then [ ep.name ] else [ ]
    else
      [ ];

  serviceKnown = endpoint:
    let serviceNames = namesForEndpoint "service" endpoint;
    in builtins.any (serviceName: builtins.hasAttr serviceName serviceBindings || builtins.hasAttr serviceName serviceRecords) serviceNames;

  serviceProviderTenants = endpoint:
    uniqueStrings (
      builtins.concatLists (
        builtins.map
          (serviceName:
            if builtins.hasAttr serviceName serviceRecords then
              listOrEmpty (serviceRecords.${serviceName}.providerTenants or null)
            else
              [ ])
          (namesForEndpoint "service" endpoint)
      )
    );

  accessNodesForEndpoint = endpoint:
    uniqueStrings (
      builtins.concatLists (
        builtins.map accessNodesForTenant (
          namesForEndpoint "tenant" endpoint
          ++ namesForEndpoint "tenant-set" endpoint
          ++ serviceProviderTenants endpoint
        )
      )
    );

  uplinksForEndpoint = endpoint:
    uniqueStrings (
      builtins.concatLists (
        builtins.map externalUplinks (namesForEndpoint "external" endpoint)
      )
    );

  accessIfacesForNodes = accessNodes:
    builtins.filter
      (iface: builtins.elem (common.laneAccess iface) accessNodes)
      accessInterfaces;

  uplinkIfacesFor = accessNodes: uplinks:
    builtins.filter
      (iface:
        (accessNodes == [ ] || builtins.elem (common.laneAccess iface) accessNodes)
        && (uplinks == [ ] || builtins.elem (common.laneUplink iface) uplinks))
      uplinkInterfaces;

  serviceIfacesFor = accessNodes: peerAccessNodes:
    if accessNodes != [ ] then
      accessIfacesForNodes accessNodes
    else
      let sameAccessUplinks = uplinkIfacesFor peerAccessNodes [ ];
      in if sameAccessUplinks != [ ] then sameAccessUplinks else uplinkInterfaces;

  relationId = relation:
    if builtins.isString (relation.id or null) && relation.id != "" then
      relation.id
    else if builtins.isString (relation.name or null) && relation.name != "" then
      relation.name
    else
      null;

  endpointIfaces = relation: endpoint: peerEndpoint:
    let
      endpointValue = attrsOrEmpty endpoint;
      peerAccessNodes = accessNodesForEndpoint peerEndpoint;
      accessNodes = accessNodesForEndpoint endpoint;
      uplinks = uplinksForEndpoint endpoint;
    in
    if (endpointValue.kind or null) == "tenant" || (endpointValue.kind or null) == "tenant-set" then
      accessIfacesForNodes accessNodes
    else if (endpointValue.kind or null) == "external" then
      uplinkIfacesFor peerAccessNodes uplinks
    else if (endpointValue.kind or null) == "service" && serviceKnown endpoint then
      serviceIfacesFor accessNodes peerAccessNodes
    else if endpointValue == "any" || endpoint == "any" then
      accessInterfaces ++ uplinkIfacesFor peerAccessNodes [ ]
    else
      [ ];

  endpointIfacesForPeerAccess = relation: endpoint: peerEndpoint: peerAccess:
    let
      endpointValue = attrsOrEmpty endpoint;
      base = endpointIfaces relation endpoint peerEndpoint;
      sameAccess = iface: common.laneAccess iface == peerAccess;
    in
    if peerAccess == null then
      base
    else if (endpointValue.kind or null) == "external" || endpointValue == "any" || endpoint == "any" then
      builtins.filter sameAccess base
    else
      base;

  relationRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromIfaces = endpointIfaces relation (relation.from or null) (relation.to or null);
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      id = relationId relation;
    in
    builtins.concatLists (
      builtins.map
        (fromIface:
          let
            toIfaces =
              endpointIfacesForPeerAccess
                relation
                (relation.to or null)
                (relation.from or null)
                (common.laneAccess fromIface);
          in
          builtins.map
            (toIface:
              {
                inherit action;
                relationId = id;
                priority = relation.priority or null;
                trafficType = relation.trafficType or "any";
                from = attrsOrEmpty (relation.from or null);
                to = attrsOrEmpty (relation.to or null);
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              })
            toIfaces)
        fromIfaces
    );
in
builtins.concatLists (builtins.map relationRules (listOrEmpty relations))
