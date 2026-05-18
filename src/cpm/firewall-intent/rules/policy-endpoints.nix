{ common, endpointContext }:

let
  inherit (endpointContext)
    accessInterfaces
    uplinkInterfaces
    accessNodesForEndpoint
    uplinksForEndpoint
    serviceKnown
    attrsOrEmpty
    ;

  accessIfacesForNodes = accessNodes:
    builtins.filter (iface: builtins.elem (common.laneAccess iface) accessNodes) accessInterfaces;

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
      let
        exact = uplinkIfacesFor peerAccessNodes uplinks;
        peerIsService = (attrsOrEmpty peerEndpoint).kind or null == "service";
      in
      if exact != [ ] || !peerIsService then exact else uplinkIfacesFor peerAccessNodes [ ]
    else if (endpointValue.kind or null) == "service" && serviceKnown endpoint then
      serviceIfacesFor accessNodes peerAccessNodes
    else if endpointValue == "any" || endpoint == "any" then
      accessInterfaces ++ uplinkIfacesFor peerAccessNodes [ ]
    else
      [ ];

in
{
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
  inherit endpointIfaces;
}
