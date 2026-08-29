{ common, endpointContext }:

let
  inherit (endpointContext)
    accessInterfaces
    uplinkInterfaces
    accessNodesForEndpoint
    uplinksForEndpoint
    uplinksForService
    serviceKnown
    attrsOrEmpty
    ;

  accessIfacesForNodes = accessNodes:
    builtins.filter (iface: builtins.elem (common.laneAccess iface) accessNodes) accessInterfaces;

  uplinkIfacesFor = accessNodes: uplinks:
    builtins.filter
      (iface:
        (accessNodes == [ ] || builtins.elem (common.laneAccess iface) accessNodes)
        && (
          uplinks == [ ]
          || builtins.elem (common.laneUplink iface) uplinks
          || builtins.any (u: builtins.elem u uplinks) (common.laneUplinks iface)
        ))
      uplinkInterfaces;

  serviceIfacesFor = endpoint: peerAccessNodes:
    let
      accessNodes = accessNodesForEndpoint endpoint;
    in
    if accessNodes != [ ] then
      accessIfacesForNodes accessNodes
    else
    # FS-315: a core-hosted service (no tenant access nodes) reaches the
    # fabric through its provider node's uplink lane(s) only. Widening to
    # `uplinkInterfaces` would copy an unassigned route into sibling policy
    # lanes and shadow the provider core's connected fabric route.
      uplinkIfacesFor peerAccessNodes (uplinksForService endpoint);

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
        hasPublicIngressAuthority =
          builtins.isAttrs (relationValue.publicIngressTupleAuthority or null);
        exact =
          if peerIsService && hasPublicIngressAuthority then
          # A public ingress relation is bound to the access node that owns
          # the target service.  Selecting every lane for the same uplink
          # widens one WAN/service tuple over unrelated tenant lanes.
            uplinkIfacesFor peerAccessNodes uplinks
          else if peerIsService then
          # Named non-public external fabrics (for example east-west) retain
          # their explicit service projection over every matching fabric
          # lane.  They do not carry public-ingress tuple authority.
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
      serviceIfacesFor endpoint peerAccessNodes
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
