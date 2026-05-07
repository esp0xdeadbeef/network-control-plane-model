{ helpers, common, siteOverlayNameSet }:

let
  inherit (helpers) sortedNames;
  inherit (common) attrsOrEmpty listContains listOrEmpty overlayNameFromInterfaceName;

  overlayNames = sortedNames siteOverlayNameSet;

  firstOverlayName = names:
    let matches = builtins.filter (name: listContains name overlayNames) names;
    in if matches == [ ] then null else builtins.head matches;

  isOverlayInterface =
    iface:
    let backingRef = attrsOrEmpty (iface.backingRef or null);
    in (iface.sourceKind or null) == "overlay" || (backingRef.kind or null) == "overlay";

  isOverlayUplinkInterface =
    iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      uplinks = listOrEmpty (backingRef.uplinks or null);
    in
    builtins.any (uplinkName: listContains uplinkName overlayNames) uplinks;

  isDelegatedOverlayIngressInterface =
    sourceNode: iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (backingRef.lane or null);
      uplinks = listOrEmpty (lane.uplinks or null);
      uplink = lane.uplink or null;
      laneUplinks = if uplinks != [ ] then uplinks else if uplink == null then [ ] else [ uplink ];
    in
    (lane.kind or null) == "access-uplink"
    && (lane.access or null) == sourceNode
    && builtins.any (uplinkName: listContains uplinkName overlayNames) laneUplinks;

  overlayNameForInterface =
    ifName: iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      uplinks = listOrEmpty (backingRef.uplinks or null);
      lane = attrsOrEmpty (backingRef.lane or null);
      laneUplinks =
        if builtins.isList (lane.uplinks or null) then
          lane.uplinks
        else if lane.uplink or null == null then
          [ ]
        else
          [ lane.uplink ];
    in
    if isOverlayInterface iface then
      backingRef.name or (overlayNameFromInterfaceName ifName)
    else if uplinks != [ ] then
      firstOverlayName uplinks
    else
      firstOverlayName laneUplinks;
in
{
  inherit isOverlayInterface overlayNameForInterface;

  egressInterfaceNames =
    targetRole: interfaces:
    builtins.filter
      (ifName:
        let iface = interfaces.${ifName};
        in isOverlayInterface iface || (targetRole != "core" && isOverlayUplinkInterface iface))
      (sortedNames interfaces);

  ingressInterfaceNames =
    sourceNode: interfaces:
    builtins.filter
      (ifName: isDelegatedOverlayIngressInterface sourceNode interfaces.${ifName})
      (sortedNames interfaces);
}
