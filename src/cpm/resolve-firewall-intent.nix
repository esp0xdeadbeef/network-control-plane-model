{ helpers }:

{
  sitePath,
  siteAttrs,
  runtimeTargets,
  policyEndpointBindings ? { },
  services ? [ ],
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

  communicationContract = attrsOrEmpty (siteAttrs.communicationContract or null);
  siteRelations =
    if builtins.isList (communicationContract.relations or null) then
      communicationContract.relations
    else
      listOrEmpty (communicationContract.allowedRelations or null);
  siteTransport = attrsOrEmpty (siteAttrs.transport or null);
  overlayList = listOrEmpty (siteTransport.overlays or null);
  overlayNames = uniqueStrings (
    sortedNames (attrsOrEmpty (siteAttrs.overlays or null))
    ++ sortedNames (attrsOrEmpty (siteAttrs.overlayReachability or null))
    ++ map (overlay: overlay.name or null) overlayList
  );
  overlayUnderlayAccessByName = builtins.listToAttrs (
    builtins.filter (entry: entry.name != null) (
      map (
        overlay:
        let
          underlayAccess = attrsOrEmpty (overlay.underlayAccess or null);
        in
        {
          name = overlay.name or null;
          value = if (underlayAccess.kind or null) == "tenant" then underlayAccess.name or null else null;
        }
      ) overlayList
    )
  );

  runtimeInterfaceRecords = import ./firewall-intent/runtime-interfaces.nix { inherit helpers; };
  buildNat = import ./firewall-intent/nat.nix { inherit helpers; };
  buildForwarding = import ./firewall-intent/forwarding.nix { inherit helpers; };
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

  targetEntries = map (
    targetName:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      target = requireAttrs targetPath runtimeTargets.${targetName};
      interfaceRecords = runtimeInterfaceRecords targetPath target;
    in
    {
      inherit targetName target interfaceRecords;
    }
  ) (sortedNames runtimeTargets);

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
        ++ overlayUnderlayAccesses
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

  natEntries = builtins.filter (entry: entry != null) (
    map (
      entry:
      if (entry.target.role or null) == "core" then
        {
          name = entry.targetName;
          value = buildNat {
            inherit
              siteAttrs
              overlayNames
              ;
            inherit (entry) interfaceRecords target;
          };
        }
      else
        null
    ) targetEntries
  );

  runtimeOriginSourcePrefixes = builtins.attrValues (
    builtins.listToAttrs (
      builtins.concatMap
        (entry:
          let
            origin = originForTarget entry.targetName entry.target;
          in
          map (prefix: {
            name = "${builtins.toString (prefix.family or "")}|${prefix.prefix or ""}";
            value = prefix // { inherit origin; };
          }) (listOrEmpty ((attrsOrEmpty (entry.target.runtimeOriginEgress or null)).sourcePrefixes or [ ])))
        targetEntries
    )
  );

  forwardingEntries = builtins.filter (entry: entry != null) (
    map (
      entry:
      let
        value = buildForwarding {
          inherit
            overlayNames
            policyEndpointBindings
            services
            siteRelations
            runtimeOriginSourcePrefixes
            ;
          inherit (entry) target interfaceRecords;
        };
      in
      if value == null then
        null
      else
        {
          name = entry.targetName;
          inherit value;
        }
    ) targetEntries
  );

  precedence = import ./firewall-intent/precedence.nix { };
  sortedForwardingEntries = precedence.sortEntries forwardingEntries;
  assertNoShadowedPolicyDenies = precedence.assertNoShadowedPolicyDenies sortedForwardingEntries;
in
{
  natByTarget = builtins.listToAttrs natEntries;
  forwardingByTarget = builtins.seq assertNoShadowedPolicyDenies (
    builtins.listToAttrs sortedForwardingEntries
  );
}
