{ helpers }:

{
  sitePath,
  siteAttrs,
  targetEntries,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs sortedNames;
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];
  uniqueStrings =
    values:
    sortedNames (
      builtins.listToAttrs (
        map (value: {
          name = value;
          value = true;
        }) (builtins.filter isNonEmptyString values)
      )
    );

  siteTransport = attrsOrEmpty (siteAttrs.transport or null);
  overlayList = listOrEmpty (siteTransport.overlays or null);

  routeList =
    iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
    in
    (if builtins.isList (routes.ipv4 or null) then routes.ipv4 else [ ])
    ++ (if builtins.isList (routes.ipv6 or null) then routes.ipv6 else [ ]);
  hasDefaultRoute =
    iface:
    builtins.any (
      route:
      builtins.isAttrs route && ((route.dst or null) == "0.0.0.0/0" || (route.dst or null) == "::/0")
    ) (routeList iface);
  laneAttrs =
    iface:
    attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);
  backingRef = iface: attrsOrEmpty (iface.backingRef or null);
  linkId = iface:
    let
      ref = backingRef iface;
    in
    if (ref.kind or null) == "link" && isNonEmptyString (ref.id or null) then ref.id else null;
  targetInterfaces =
    target:
    builtins.attrValues (attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null));
  hasForwardingFunction = function: target:
    builtins.elem function (if builtins.isList (target.forwardingFunctions or null) then target.forwardingFunctions else [ ]);
  isAccessTarget =
    target: (target.role or null) == "access" || hasForwardingFunction "access-gateway" target;

  tenantAccessNodes =
    tenantName:
    uniqueStrings (
      map (entry: entry.target.logicalNode.name or null) (
        builtins.filter
          (
            entry:
            isAccessTarget entry.target
            && builtins.any
              (
                iface:
                (iface.sourceKind or null) == "tenant"
                && (toString (iface.tenant or "")) == (toString tenantName)
              )
              (targetInterfaces entry.target)
          )
          targetEntries
      )
    );

  underlayAccessNodes =
    underlayAccess:
    if (underlayAccess.kind or null) == "tenant" then tenantAccessNodes (underlayAccess.name or "") else [ ];

  overlayReachability = attrsOrEmpty (siteAttrs.overlayReachability or null);
  overlayUnderlayAccessByName =
    let
      fromTransport = map (
        overlay:
        {
          name = overlay.name or null;
          value = underlayAccessNodes (attrsOrEmpty (overlay.underlayAccess or null));
        }
      ) overlayList;
      fromReachability = map (
        name:
        {
          inherit name;
          value = underlayAccessNodes (attrsOrEmpty (overlayReachability.${name}.underlayAccess or null));
        }
      ) (sortedNames overlayReachability);
    in
    builtins.listToAttrs (
      builtins.filter (entry: entry.name != null && entry.value != [ ]) (fromTransport ++ fromReachability)
    );

  peerAccessesForLink =
    targetName: iface:
    let
      id = linkId iface;
      peerEntries =
        if id == null then
          [ ]
        else
          builtins.filter (
            peer:
            peer.targetName != targetName
            && isAccessTarget peer.target
            && builtins.any (peerIface: linkId peerIface == id) (targetInterfaces peer.target)
          ) targetEntries;
    in
    map (peer: peer.target.logicalNode or null) peerEntries;

  originForTarget =
    targetName: target:
    let
      defaultIfaces = builtins.filter hasDefaultRoute (targetInterfaces target);
      laneValues = map laneAttrs defaultIfaces;
      runtimeOrigin = attrsOrEmpty (target.runtimeOriginEgress or null);
      runtimeUplinks =
        if builtins.isList (runtimeOrigin.uplinks or null) then runtimeOrigin.uplinks else [ ];
      overlayUnderlayAccesses = map (
        uplink: overlayUnderlayAccessByName.${uplink} or null
      ) runtimeUplinks;
    in
    {
      inherit targetName;
      interfaces = uniqueStrings (map (iface: iface.runtimeIfName or null) defaultIfaces);
      accesses = uniqueStrings (
        map (lane: lane.access or null) laneValues
        ++ builtins.concatMap (value: if builtins.isList value then value else [ ]) overlayUnderlayAccesses
        ++ builtins.concatMap (peerAccessesForLink targetName) defaultIfaces
      );
      uplinks = uniqueStrings (
        builtins.concatMap (
          lane:
          (if builtins.isString (lane.uplink or null) then [ lane.uplink ] else [ ])
          ++ (if builtins.isList (lane.uplinks or null) then lane.uplinks else [ ])
        ) laneValues
      );
    };

in
builtins.attrValues (
  builtins.listToAttrs (
    builtins.concatMap
      (entry:
        let
          targetPath = "${sitePath}.runtimeTargets.${entry.targetName}";
          target = requireAttrs targetPath entry.target;
          origin = originForTarget entry.targetName target;
        in
        map (prefix: {
          name = "${builtins.toString (prefix.family or "")}|${prefix.prefix or ""}";
          value = prefix // { inherit origin; };
        }) (listOrEmpty ((attrsOrEmpty (target.runtimeOriginEgress or null)).sourcePrefixes or [ ])))
      targetEntries
  )
)
