{
  lib,
  helpers,
  common,
  siteAttrs,
  allRuntimeRoutedIPv6Prefixes,
  siteOverlayNameSet,
  routeExists,
  buildRoute,
}:

let
  inherit (helpers) hasAttr sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;
  p2pPeers = import ../../ControlModule/route-augmentation/p2p-peers.nix { inherit lib; };

  siteId = siteAttrs.siteId or null;

  prefixHasSourceFile =
    prefix: builtins.isAttrs prefix && builtins.isString (prefix.sourceFile or null) && prefix.sourceFile != "";

  remoteRuntimeRoutedPrefixes =
    builtins.filter
      (prefix:
        builtins.isAttrs prefix
        && (prefix.siteId or null) != siteId
        && (prefix.family or null) == "ipv6"
        && (prefix.allocation or null) == "runtime"
        && prefixHasSourceFile prefix)
      allRuntimeRoutedIPv6Prefixes;

  routeForRemotePrefix =
    iface: prefix:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      isOverlay = (backingRef.kind or null) == "overlay" || (iface.sourceKind or null) == "overlay";
      peer = p2pPeers.peerForInterface 6 iface;
      proto = if isOverlay then "overlay" else "internal";
    in
    if !isOverlay && peer == null then
      null
    else
      buildRoute (prefix.accessNode or "remote-runtime-routed-prefix") prefix (if isOverlay then null else peer) proto;

  addRemotePrefixRoutesToInterface =
    iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
      existing = listOrEmpty (routes.ipv6 or null);
      updated =
        builtins.foldl'
          (acc: prefix:
            let route = routeForRemotePrefix iface prefix;
            in
            if route == null || routeExists acc prefix.sourceFile (route.via6 or null) (route.proto or null) then
              acc
            else
              acc ++ [ route ])
          existing
          remoteRuntimeRoutedPrefixes;
    in
    iface // { routes = routes // { ipv6 = updated; }; };

  targetHasOverlayInterface =
    interfaces:
    builtins.any
      (ifName:
        let
          iface = attrsOrEmpty (interfaces.${ifName} or null);
          backingRef = attrsOrEmpty (iface.backingRef or null);
        in
        (backingRef.kind or null) == "overlay" || (iface.sourceKind or null) == "overlay")
      (sortedNames interfaces);

  isRemoteReturnInterface =
    targetRole: hasOverlay: iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (backingRef.lane or null);
      laneUplinks =
        if builtins.isList (lane.uplinks or null) then
          lane.uplinks
        else if lane.uplink or null == null then
          [ ]
        else
          [ lane.uplink ];
      laneUsesOverlay = builtins.any (uplinkName: hasAttr uplinkName siteOverlayNameSet) laneUplinks;
      isOverlayUplink = (lane.kind or null) == "uplink" && laneUsesOverlay;
      isTransit = (backingRef.kind or null) == "link" && (iface.addr6 or null) != null;
      isOverlay = (backingRef.kind or null) == "overlay" || (iface.sourceKind or null) == "overlay";
    in
    remoteRuntimeRoutedPrefixes != [ ]
    && (
      (targetRole == "core" && (if hasOverlay then isOverlay else isTransit))
      || (targetRole == "upstream-selector" && isOverlayUplink)
    );

in
target:
let
  targetRole = target.role or null;
  effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
  interfaces = attrsOrEmpty (effective.interfaces or null);
  hasOverlay = targetHasOverlayInterface interfaces;
  updatedInterfaces =
    builtins.mapAttrs
      (_: iface:
        if isRemoteReturnInterface targetRole hasOverlay iface then
          addRemotePrefixRoutesToInterface iface
        else
          iface)
      interfaces;
in
target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; }
