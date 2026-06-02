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
      relationValue = attrsOrEmpty relation;
      endpointValue = attrsOrEmpty endpoint;
      peerAccessNodes = accessNodesForEndpoint peerEndpoint;
      accessNodes = accessNodesForEndpoint endpoint;
      uplinks = uplinksForEndpoint endpoint;
      isDeny = (relationValue.action or "allow") == "deny";
    in
    if (endpointValue.kind or null) == "tenant" || (endpointValue.kind or null) == "tenant-set" then
      accessIfacesForNodes accessNodes
    else if (endpointValue.kind or null) == "external" then
      let
        peerIsService = (attrsOrEmpty peerEndpoint).kind or null == "service";
        exact =
          if peerIsService then
            uplinkIfacesFor [ ] uplinks
          else
            uplinkIfacesFor peerAccessNodes uplinks;
        denyFallback = if isDeny then uplinkIfacesFor [ ] uplinks else [ ];
      in
      if exact != [ ] then
        exact
      else if peerIsService then
        uplinkIfacesFor peerAccessNodes [ ]
      else
        denyFallback
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
      relationValue = attrsOrEmpty relation;
      endpointValue = attrsOrEmpty endpoint;
      base = endpointIfaces relation endpoint peerEndpoint;
      sameAccess = iface: common.laneAccess iface == peerAccess;
      sameAccessBase = builtins.filter sameAccess base;
    in
    if peerAccess == null then
      base
    else if (endpointValue.kind or null) == "external" then
      if sameAccessBase != [ ] || (relationValue.action or "allow") != "deny" then sameAccessBase else base
    else if endpointValue == "any" || endpoint == "any" then
      sameAccessBase
    else
      base;
  inherit endpointIfaces;
}
