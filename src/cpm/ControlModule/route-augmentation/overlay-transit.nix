{
  helpers,
  common,
  routeHelpers,
  sitePath,
  overlayNames,
  overlayTransitEndpointAddressesByOverlay,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;
  inherit (routeHelpers)
    buildOverlayTransitEndpointRoute
    routeGatewayForPrefix
    routeWithDstPresent
    routeWithExactDstPresent
    ;
in
targetName: target:
let
  targetPath = "${sitePath}.runtimeTargets.${targetName}";
  effective =
    requireAttrs
      "${targetPath}.effectiveRuntimeRealization"
      (target.effectiveRuntimeRealization or null);
  interfaces =
    requireAttrs
      "${targetPath}.effectiveRuntimeRealization.interfaces"
      (effective.interfaces or null);

  updatedInterfaces =
    builtins.mapAttrs
      (_: iface:
        let
          backingRef = attrsOrEmpty (iface.backingRef or null);
          overlayName =
            if (backingRef.kind or null) == "overlay" && isNonEmptyString (backingRef.name or null) then
              backingRef.name
            else
              null;
          routes = attrsOrEmpty (iface.routes or null);
          existingV4 = listOrEmpty (routes.ipv4 or null);
          existingV6 = listOrEmpty (routes.ipv6 or null);
          overlaysForInterface =
            if overlayName != null then
              [ overlayName ]
            else
              builtins.filter
                (candidateOverlayName:
                  let
                    candidateOverlay = attrsOrEmpty (overlayTransitEndpointAddressesByOverlay.${candidateOverlayName} or null);
                    peerPrefixes4 = listOrEmpty (candidateOverlay.peerPrefixes4 or null);
                    peerPrefixes6 = listOrEmpty (candidateOverlay.peerPrefixes6 or null);
                  in
                  builtins.any (dst: routeWithExactDstPresent existingV4 dst) peerPrefixes4
                  || builtins.any (dst: routeWithExactDstPresent existingV6 dst) peerPrefixes6)
                overlayNames;

          overlayExtraRoutes =
            builtins.map
              (candidateOverlayName:
                let
                  candidateOverlay = attrsOrEmpty (overlayTransitEndpointAddressesByOverlay.${candidateOverlayName} or null);
                  peerEntries0 = listOrEmpty (candidateOverlay.peerEntries or null);
                  peerEntries =
                    if peerEntries0 != [ ] then
                      peerEntries0
                    else
                      [
                        {
                          peerSite = candidateOverlay.peerSite or null;
                          byNode = attrsOrEmpty (candidateOverlay.byNode or null);
                          peerPrefixes4 = listOrEmpty (candidateOverlay.peerPrefixes4 or null);
                          peerPrefixes6 = listOrEmpty (candidateOverlay.peerPrefixes6 or null);
                        }
                      ];
                  peerPrefixes4 = listOrEmpty (candidateOverlay.peerPrefixes4 or null);
                  peerPrefixes6 = listOrEmpty (candidateOverlay.peerPrefixes6 or null);
                  gateway4 = if overlayName != null then null else routeGatewayForPrefix 4 existingV4 peerPrefixes4;
                  gateway6 = if overlayName != null then null else routeGatewayForPrefix 6 existingV6 peerPrefixes6;
                  routesForEntry =
                    entry:
                    let
                      peerSite = entry.peerSite or null;
                      byNode = attrsOrEmpty (entry.byNode or null);
                      extraForFamily =
                        family: nodeName: gateway: existingRoutes: addresses:
                        builtins.map
                          (address: buildOverlayTransitEndpointRoute family candidateOverlayName peerSite address nodeName gateway)
                          (builtins.filter (address: !routeWithDstPresent family existingRoutes address) addresses);
                      routesForNode =
                        nodeName:
                        let
                          addresses = attrsOrEmpty (byNode.${nodeName} or null);
                        in
                        {
                          ipv4 = extraForFamily 4 nodeName gateway4 existingV4 (listOrEmpty (addresses.ipv4 or null));
                          ipv6 = extraForFamily 6 nodeName gateway6 existingV6 (listOrEmpty (addresses.ipv6 or null));
                        };
                      byNodeRoutes =
                        if !isNonEmptyString peerSite then
                          [ ]
                        else
                          builtins.map routesForNode (sortedNames byNode);
                    in
                    {
                      ipv4 = builtins.concatLists (builtins.map (entry: entry.ipv4) byNodeRoutes);
                      ipv6 = builtins.concatLists (builtins.map (entry: entry.ipv6) byNodeRoutes);
                    };
                  entryRoutes = builtins.map routesForEntry peerEntries;
                in
                {
                  ipv4 = builtins.concatLists (builtins.map (entry: entry.ipv4) entryRoutes);
                  ipv6 = builtins.concatLists (builtins.map (entry: entry.ipv6) entryRoutes);
                })
              overlaysForInterface;
          extraV4 = builtins.concatLists (builtins.map (entry: entry.ipv4) overlayExtraRoutes);
          extraV6 = builtins.concatLists (builtins.map (entry: entry.ipv6) overlayExtraRoutes);
        in
        if overlaysForInterface == [ ] then
          iface
        else
          iface // { routes = routes // { ipv4 = existingV4 ++ extraV4; ipv6 = existingV6 ++ extraV6; }; })
      interfaces;
in
target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; }
