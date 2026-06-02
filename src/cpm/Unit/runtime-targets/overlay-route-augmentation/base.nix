{ lib
, helpers
, common
, ipam
, overlayProvisioning
, attachments
, routedPrefixesByTenant
,
}:

let
  inherit (helpers) hasAttr isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;

  overlayUnderlayEndpoints =
    let
      keyed = builtins.listToAttrs (
        builtins.map
          (endpoint: {
            name = "${toString (endpoint.family or "")}|${endpoint.sourceFile or ""}";
            value = endpoint;
          })
          (
            builtins.filter
              (endpoint: builtins.isAttrs endpoint && isNonEmptyString (endpoint.sourceFile or null))
              (lib.concatLists (
                builtins.map
                  (overlayName:
                    builtins.map
                      (endpoint: endpoint // { overlay = overlayName; })
                      (builtins.filter builtins.isAttrs (listOrEmpty (overlayProvisioning.${overlayName}.underlayEndpoints or null))))
                  (sortedNames overlayProvisioning)
              ))
          )
      );
    in
    builtins.map (key: keyed.${key}) (sortedNames keyed);

  p2pPeerAddress =
    family: cidr:
    let
      parsed = if builtins.isString cidr then ipam.splitCIDR cidr else null;
      expectedPrefixLen = if family == 4 then 31 else 127;
      parsedAddress =
        if parsed == null || parsed.prefixLen != expectedPrefixLen then
          null
        else if family == 4 then
          ipam.parseIPv4 parsed.addr
        else
          ipam.parseIPv6 parsed.addr;
      ipv4PeerInt =
        if parsedAddress == null || family != 4 then
          null
        else
          let
            addrInt = ipam.ipv4ToInt parsedAddress;
          in
          if lib.mod addrInt 2 == 0 then addrInt + 1 else addrInt - 1;
      ipv6Peer =
        if parsedAddress == null || family != 6 then
          null
        else
          builtins.genList
            (
              idx:
              if idx == 7 then
                if lib.mod (builtins.elemAt parsedAddress 7) 2 == 0 then
                  (builtins.elemAt parsedAddress 7) + 1
                else
                  (builtins.elemAt parsedAddress 7) - 1
              else
                builtins.elemAt parsedAddress idx
            )
            8;
    in
    if parsedAddress == null then
      null
    else if family == 4 then
      ipam.renderIPv4 (ipam.ipv4FromInt ipv4PeerInt)
    else
      ipam.renderIPv6 ipv6Peer;

  interfaceOverlayLaneNames =
    iface:
    let
      backingRef = iface.backingRef or { };
      lane = backingRef.lane or { };
      uplinks = (listOrEmpty (backingRef.uplinks or null)) ++ (listOrEmpty (lane.uplinks or null));
      single = lane.uplink or null;
    in
    if (lane.kind or null) != "uplink" then
      [ ]
    else
      uplinks ++ (if isNonEmptyString single then [ single ] else [ ]);

  interfaceOverlayNames =
    interfaces:
    builtins.filter
      (overlayName: hasAttr overlayName overlayProvisioning)
      (lib.unique (
        lib.concatMap
          (
            ifName:
            let
              iface = interfaces.${ifName};
            in
            if (iface.sourceKind or null) == "overlay" then [ ((iface.backingRef or { }).name or null) ] else [ ]
          )
          (sortedNames interfaces)
      ));

  defaultViaRoutes =
    family: routes:
    builtins.filter
      (route: ((route.intent or { }).kind or null) == "default-reachability" && (route.${if family == 4 then "via4" else "via6"} or null) != null)
      (listOrEmpty (routes.${if family == 4 then "ipv4" else "ipv6"} or null));

  defaultViaFor =
    family: interfaces:
    let
      viaField = if family == 4 then "via4" else "via6";
      candidates =
        lib.concatMap
          (
            ifName:
            let
              iface = interfaces.${ifName};
              laneUplinks = interfaceOverlayLaneNames iface;
              routes = attrsOrEmpty (iface.routes or null);
            in
            if (iface.sourceKind or null) != "p2p" || builtins.any (name: hasAttr name overlayProvisioning) laneUplinks then
              [ ]
            else
              builtins.map (route: route.${viaField}) (defaultViaRoutes family routes)
          )
          (sortedNames interfaces);
    in
    if candidates == [ ] then null else builtins.head candidates;

  tenantsWithRuntimePrefixes =
    lib.filter
      (
        tenantName:
        builtins.any
          (prefix: (prefix.allocation or null) == "runtime" || (prefix.source or null) == "intent-routed-prefix")
          (listOrEmpty (routedPrefixesByTenant.${tenantName} or null))
      )
      (sortedNames routedPrefixesByTenant);

  runtimePrefixExitNodes =
    lib.unique (
      lib.concatMap
        (
          tenantName:
          builtins.map
            (attachment: attachment.unit)
            (
              builtins.filter
                (attachment: (attachment.kind or null) == "tenant" && (attachment.name or null) == tenantName && isNonEmptyString (attachment.unit or null))
                (listOrEmpty attachments)
            )
        )
        tenantsWithRuntimePrefixes
    );
in
{
  inherit
    defaultViaFor
    defaultViaRoutes
    interfaceOverlayLaneNames
    interfaceOverlayNames
    overlayUnderlayEndpoints
    p2pPeerAddress
    runtimePrefixExitNodes
    ;
}
