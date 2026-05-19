{
  lib,
  helpers,
  common,
  ipam,
  overlayProvisioning,
}:

let
  inherit (helpers) hasAttr isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;

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
          let addrInt = ipam.ipv4ToInt parsedAddress;
          in if lib.mod addrInt 2 == 0 then addrInt + 1 else addrInt - 1;
      ipv6Peer =
        if parsedAddress == null || family != 6 then
          null
        else
          builtins.genList
            (idx: if idx == 7 then (if lib.mod (builtins.elemAt parsedAddress 7) 2 == 0 then (builtins.elemAt parsedAddress 7) + 1 else (builtins.elemAt parsedAddress 7) - 1) else builtins.elemAt parsedAddress idx)
            8;
    in
    if parsedAddress == null then null else if family == 4 then ipam.renderIPv4 (ipam.ipv4FromInt ipv4PeerInt) else ipam.renderIPv6 ipv6Peer;
  interfaceOverlayLaneNames =
    iface:
    let
      lane = ((iface.backingRef or { }).lane or { });
      uplinks = listOrEmpty (lane.uplinks or null);
      single = lane.uplink or null;
    in
    if (lane.kind or null) != "uplink" then [ ] else uplinks ++ (if isNonEmptyString single then [ single ] else [ ]);
  interfaceOverlayNames =
    interfaces:
    builtins.filter
      (overlayName: hasAttr overlayName overlayProvisioning)
      (lib.unique (
        lib.concatMap
          (ifName:
            let iface = interfaces.${ifName};
            in if (iface.sourceKind or null) == "overlay" then [ ((iface.backingRef or { }).name or null) ] else [ ])
          (sortedNames interfaces)
      ));

  defaultViaRoutes =
    family: routes:
    builtins.filter
      (route: ((route.intent or { }).kind or null) == "default-reachability" && (route.${if family == 4 then "via4" else "via6"} or null) != null)
      (listOrEmpty (routes.${if family == 4 then "ipv4" else "ipv6"} or null));

  underlayEndpointRoutes =
    family: routes:
    let
      viaField = if family == 4 then "via4" else "via6";
      endpoints = builtins.filter (endpoint: (endpoint.family or null) == family && isNonEmptyString (endpoint.sourceFile or null)) overlayUnderlayEndpoints;
    in
    lib.concatMap
      (defaultRoute:
        builtins.map
          (endpoint: {
            inherit family;
            sourceFile = endpoint.sourceFile;
            proto = "underlay";
            overlay = endpoint.overlay;
            intent = { kind = "overlay-underlay-reachability"; source = "overlay-underlay-endpoint"; };
            ${viaField} = defaultRoute.${viaField};
          })
          endpoints)
      (defaultViaRoutes family routes);

  overlayEndpointRoutesVia =
    family: overlayNamesForInterface: via:
    let
      viaField = if family == 4 then "via4" else "via6";
      endpoints =
        builtins.filter
          (endpoint: (endpoint.family or null) == family && isNonEmptyString (endpoint.sourceFile or null) && builtins.elem (endpoint.overlay or null) overlayNamesForInterface)
          overlayUnderlayEndpoints;
    in
    if !isNonEmptyString via then [ ] else builtins.map (endpoint: {
      inherit family;
      sourceFile = endpoint.sourceFile;
      proto = "underlay";
      overlay = endpoint.overlay;
      intent = { kind = "overlay-underlay-reachability"; source = "overlay-underlay-endpoint"; };
      ${viaField} = via;
    }) endpoints;

  overlayNodeRoutesVia =
    family: overlayNamesForInterface: via:
    let
      viaField = if family == 4 then "via4" else "via6";
      prefixField = if family == 4 then "ipv4" else "ipv6";
      prefixes = lib.unique (lib.concatMap (overlayName: listOrEmpty (overlayProvisioning.${overlayName}.nodeRoutePrefixes.${prefixField} or null)) overlayNamesForInterface);
    in
    if !isNonEmptyString via then [ ] else builtins.map (dst: {
      inherit dst family;
      proto = "internal";
      intent = { kind = "overlay-node-reachability"; };
      ${viaField} = via;
    }) prefixes;

  overlayRuntimeRoutedPrefixRoutesVia =
    overlayNamesForInterface: via:
    let prefixes = lib.unique (lib.concatMap (overlayName: listOrEmpty (overlayProvisioning.${overlayName}.peerRuntimeRoutedPrefixes or null)) overlayNamesForInterface);
    in
    if !isNonEmptyString via then [ ] else builtins.map (prefix: prefix // {
      proto = "overlay";
      intent = { kind = "runtime-routed-prefix-return"; source = "intent-routed-prefix"; };
      via6 = via;
    }) prefixes;

  addOverlayNodeRoutesToSelector =
    nodeRole: interfaces:
    if !(nodeRole == "policy" || nodeRole == "upstream-selector") then
      interfaces
    else
      lib.mapAttrs
        (_: iface:
          let
            laneOverlayNames = builtins.filter (name: builtins.elem name (sortedNames overlayProvisioning)) (interfaceOverlayLaneNames iface);
            routes = attrsOrEmpty (iface.routes or null);
            extraRoutes = {
              ipv4 = overlayNodeRoutesVia 4 laneOverlayNames (p2pPeerAddress 4 (iface.addr4 or null));
              ipv6 = (overlayNodeRoutesVia 6 laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null))) ++ (overlayRuntimeRoutedPrefixRoutesVia laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null)));
            };
          in
          if (iface.sourceKind or null) != "p2p" || laneOverlayNames == [ ] || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ]) then iface else iface // { routes = mergeRoutes routes extraRoutes; })
        interfaces;

  addOverlayUnderlayEndpointRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" || overlayUnderlayEndpoints == [ ] then
      interfaces
    else
      let nodeOverlayNames = interfaceOverlayNames interfaces;
      in
      if nodeOverlayNames == [ ] then interfaces else lib.mapAttrs (_: iface:
        let
          laneOverlayNames = builtins.filter (name: builtins.elem name nodeOverlayNames) (interfaceOverlayLaneNames iface);
          routes = attrsOrEmpty (iface.routes or null);
          extraRoutes = {
            ipv4 = overlayEndpointRoutesVia 4 laneOverlayNames (p2pPeerAddress 4 (iface.addr4 or null));
            ipv6 = overlayEndpointRoutesVia 6 laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null));
          };
        in
        if (iface.sourceKind or null) != "p2p" || laneOverlayNames == [ ] || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ]) then iface else iface // { routes = mergeRoutes routes extraRoutes; }) interfaces;
in
nodeRole: interfaces:
let coreInterfaces = addOverlayUnderlayEndpointRoutesToCore nodeRole (addOverlayNodeRoutesToSelector nodeRole interfaces);
in
if nodeRole != "upstream-selector" || overlayUnderlayEndpoints == [ ] then
  coreInterfaces
else
  lib.mapAttrs
    (_: iface:
      let
        routes = attrsOrEmpty (iface.routes or null);
        extraRoutes = { ipv4 = underlayEndpointRoutes 4 routes; ipv6 = underlayEndpointRoutes 6 routes; };
      in
      if extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ] then iface else iface // { routes = mergeRoutes routes extraRoutes; })
    coreInterfaces
