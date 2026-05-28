{
  lib,
  helpers,
  common,
  overlayProvisioning,
  p2pPeerAddress,
  overlayNodeRoutesVia,
  overlayRuntimeRoutedPrefixRoutesVia,
}:

let
  inherit (helpers) hasAttr isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;

  laneOverlayNamesFor =
    nodeRole: iface:
    let
      lane = ((iface.backingRef or { }).lane or { });
      uplinks = listOrEmpty (lane.uplinks or null);
      single = lane.uplink or null;
      laneNames = uplinks ++ (if isNonEmptyString single then [ single ] else [ ]);
      overlayLaneNames = builtins.filter (name: builtins.elem name (sortedNames overlayProvisioning)) laneNames;
      overlayAwareLane =
        (lane.kind or null) == "uplink"
        || (nodeRole == "policy" && (lane.kind or null) == "access-uplink");
    in
    if overlayAwareLane then overlayLaneNames else [ ];

  overlayNodeRoutesOnLink =
    family: overlayName: ownCidr:
    let
      prefixField = if family == 4 then "ipv4" else "ipv6";
      prefixes = listOrEmpty (overlayProvisioning.${overlayName}.nodeRoutePrefixes.${prefixField} or null);
    in
    builtins.map
      (dst: {
        inherit dst family;
        proto = "overlay";
        scope = "link";
        intent = {
          kind = "overlay-node-reachability";
          source = "overlay-node-prefix";
        };
      })
      (builtins.filter (dst: dst != ownCidr) prefixes);

  addOverlayNodeRoutesToSelector =
    nodeRole: interfaces:
    if !(nodeRole == "policy" || nodeRole == "upstream-selector") then
      interfaces
    else
      lib.mapAttrs (
        _: iface:
        let
          laneOverlayNames = laneOverlayNamesFor nodeRole iface;
          routes = attrsOrEmpty (iface.routes or null);
          extraRoutes = {
            ipv4 = overlayNodeRoutesVia 4 laneOverlayNames (p2pPeerAddress 4 (iface.addr4 or null));
            ipv6 =
              (overlayNodeRoutesVia 6 laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null)))
              ++ (overlayRuntimeRoutedPrefixRoutesVia laneOverlayNames (p2pPeerAddress 6 (iface.addr6 or null)));
          };
        in
        if
          (iface.sourceKind or null) != "p2p"
          || laneOverlayNames == [ ]
          || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ])
        then
          iface
        else
          iface // { routes = mergeRoutes routes extraRoutes; }
      ) interfaces;

  addOverlayNodeRoutesToCoreOverlay =
    nodeRole: interfaces:
    if nodeRole != "core" then
      interfaces
    else
      lib.mapAttrs (
        _: iface:
        let
          overlayName = ((iface.backingRef or { }).name or null);
          routes = attrsOrEmpty (iface.routes or null);
          extraRoutes = {
            ipv4 =
              if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
                overlayNodeRoutesOnLink 4 overlayName (iface.addr4 or null)
              else
                [ ];
            ipv6 =
              if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
                overlayNodeRoutesOnLink 6 overlayName (iface.addr6 or null)
              else
                [ ];
          };
        in
        if (iface.sourceKind or null) != "overlay" || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ]) then
          iface
        else
          iface // { routes = mergeRoutes routes extraRoutes; }
      ) interfaces;
in
{
  inherit
    addOverlayNodeRoutesToSelector
    addOverlayNodeRoutesToCoreOverlay
    ;
}
