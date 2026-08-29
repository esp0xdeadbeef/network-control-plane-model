{ helpers
, common
, inventoryAttrs
, siteAttrs
, sitePath
, enterpriseName
, siteName
, uplinkNames
,
}:

let
  inherit (helpers)
    isNonEmptyString
    requireList
    requireString
    sortedNames
    ;

  inherit (common)
    attrsOrEmpty
    failInventory
    ;

  siteControlPlaneCfg =
    let
      cp = attrsOrEmpty (inventoryAttrs.controlPlane or null);
      sitesCfg = attrsOrEmpty (cp.sites or null);
      enterpriseCfg = attrsOrEmpty (sitesCfg.${enterpriseName} or null);
    in
    attrsOrEmpty (enterpriseCfg.${siteName} or null);

  siteRouting = attrsOrEmpty (siteControlPlaneCfg.routing or null);
  siteOverlays = attrsOrEmpty (siteControlPlaneCfg.overlays or null);
  siteUplinksCfg = attrsOrEmpty (siteControlPlaneCfg.uplinks or null);
  siteTenantsCfg = attrsOrEmpty (siteControlPlaneCfg.tenants or null);
  siteIpv6Cfg = attrsOrEmpty (siteAttrs.ipv6 or null) // attrsOrEmpty (siteControlPlaneCfg.ipv6 or null);

  # FS-481: routing style is selected per modeled boundary in the intent
  # topology (uplink egress mode), never from a site-wide inventory mode.
  intentUplinkEgressModes =
    builtins.concatMap
      (nodeName:
        builtins.map
          (uplinkName:
            let
              node = attrsOrEmpty (siteAttrs.nodes.${nodeName} or null);
              uplinks = attrsOrEmpty (node.uplinks or null);
              uplink = attrsOrEmpty (uplinks.${uplinkName} or null);
              egress = attrsOrEmpty (uplink.egress or null);
            in
            egress.mode or "static")
          (builtins.attrNames (attrsOrEmpty ((attrsOrEmpty (siteAttrs.nodes.${nodeName} or null)).uplinks or null))))
      (builtins.attrNames (attrsOrEmpty (siteAttrs.nodes or null)));

  routingMode = if builtins.elem "bgp" intentUplinkEgressModes then "bgp" else "static";

  bgpSite =
    if routingMode == "bgp" then
      attrsOrEmpty (siteRouting.bgp or null)
    else
      { };

  bgpSiteAsn =
    if routingMode != "bgp" then
      null
    else if builtins.isInt (bgpSite.asn or null) then
      bgpSite.asn
    else
      failInventory
        "inventory.controlPlane.sites.${enterpriseName}.${siteName}.routing.bgp.asn"
        "routing.bgp.asn is required and must be an integer when routing.mode = \"bgp\"";
  bgpTopology = bgpSite.topology or "policy-rr";

  normalizeEgressMode = v:
    if v == "static" || v == "bgp" then v else "static";

  modeledUplinkPrefixes =
    uplinkName: family:
    builtins.concatLists (
      builtins.map
        (nodeName:
          let
            node = attrsOrEmpty (siteAttrs.nodes.${nodeName} or null);
            uplinks = attrsOrEmpty (node.uplinks or null);
            uplink = attrsOrEmpty (uplinks.${uplinkName} or null);
            prefixes = if builtins.isList (uplink.${family} or null) then uplink.${family} else [ ];
          in
          builtins.genList
            (idx: {
              prefix = builtins.elemAt prefixes idx;
              behaviorRef = "${sitePath}.nodes.${nodeName}.uplinks.${uplinkName}.${family}[${toString idx}]";
            })
            (builtins.length prefixes))
        (sortedNames (siteAttrs.nodes or { }))
    );

  routePrefix = routePath: route:
    requireString "${routePath}.prefix" (route.prefix or route.dst or null);

  routeVia = family: routePath: route:
    requireString "${routePath}.via" (route.via or route.${if family == "ipv4" then "via4" else "via6"} or null);

  authorizeStaticRoute = uplinkName: family: idx: routeValue:
    let
      routePath = "inventory.controlPlane.sites.${enterpriseName}.${siteName}.uplinks.${uplinkName}.egress.static.routes.${family}[${toString idx}]";
      route =
        if builtins.isAttrs routeValue then
          routeValue
        else
          failInventory routePath "must be an attribute set";
      prefix = routePrefix routePath route;
      via = routeVia family routePath route;
      matching =
        builtins.filter (entry: entry.prefix == prefix) (modeledUplinkPrefixes uplinkName family);
      _authorized =
        if matching != [ ] then
          true
        else
          failInventory routePath
            "UNAUTHORIZED_BEHAVIOR_FROM_INVENTORY source=public-inventory record=wanEgressRoute prefix=${prefix} gateway=${via}: inventory static uplink route creates behavior absent from intent-authorized model";
      behaviorRef = (builtins.head matching).behaviorRef;
      explicitTrace = route.traceBackRef or route.upstreamBehaviorRef or null;
      _trace =
        if explicitTrace == null || explicitTrace == behaviorRef then
          true
        else
          failInventory routePath
            "UNTRACEABLE_ROUTE scope=${enterpriseName}.${siteName}.${uplinkName} destination=${prefix} nextHop=${via}: traceBackRef '${explicitTrace}' does not match authorized behavior '${behaviorRef}'";
    in
    builtins.seq _authorized (
      builtins.seq _trace (
        route
        // {
          traceBackRef = behaviorRef;
          upstreamBehaviorRef = behaviorRef;
          binderSourcePath = routePath;
        }
      )
    );

  authorizeStaticRoutes = uplinkName: family: routes:
    builtins.genList
      (idx: authorizeStaticRoute uplinkName family idx (builtins.elemAt routes idx))
      (builtins.length routes);

  uplinkRouting =
    builtins.listToAttrs (
      builtins.map
        (uplinkName:
          let
            uplinkPath = "inventory.controlPlane.sites.${enterpriseName}.${siteName}.uplinks.${uplinkName}.egress";
            uplinkCfg = attrsOrEmpty (siteUplinksCfg.${uplinkName} or null);
            egress = attrsOrEmpty (uplinkCfg.egress or null);
            modeRaw = egress.mode or "static";
            mode = normalizeEgressMode modeRaw;

            staticCfg = attrsOrEmpty (egress.static or null);
            staticRoutes = attrsOrEmpty (staticCfg.routes or null);
            staticRoutes4 = requireList "${uplinkPath}.static.routes.ipv4" (staticRoutes.ipv4 or [ ]);
            staticRoutes6 = requireList "${uplinkPath}.static.routes.ipv6" (staticRoutes.ipv6 or [ ]);

            bgpCfg = attrsOrEmpty (egress.bgp or null);
            bgpPeerAsn = bgpCfg.peerAsn or null;
            bgpPeerAddr4 = bgpCfg.peerAddr4 or null;
            bgpPeerAddr6 = bgpCfg.peerAddr6 or null;

            _bgpValid =
              if mode != "bgp" then
                true
              else if !builtins.isInt bgpPeerAsn then
                failInventory "${uplinkPath}.bgp.peerAsn" "bgp uplink egress requires integer peerAsn"
              else if !(isNonEmptyString bgpPeerAddr4 || isNonEmptyString bgpPeerAddr6) then
                failInventory "${uplinkPath}.bgp" "bgp uplink egress requires peerAddr4 and/or peerAddr6"
              else
                true;
          in
          builtins.seq _bgpValid {
            name = uplinkName;
            value =
              {
                mode = mode;
              }
              // (
                if mode == "static" && builtins.isAttrs (staticCfg.routes or null) then
                  {
                    static = {
                      routes = {
                        ipv4 = authorizeStaticRoutes uplinkName "ipv4" staticRoutes4;
                        ipv6 = authorizeStaticRoutes uplinkName "ipv6" staticRoutes6;
                      };
                    };
                  }
                else
                  { }
              )
              // (
                if mode == "bgp" then
                  {
                    bgp =
                      {
                        peerAsn = bgpPeerAsn;
                      }
                      // (if isNonEmptyString bgpPeerAddr4 then { peerAddr4 = bgpPeerAddr4; } else { })
                      // (if isNonEmptyString bgpPeerAddr6 then { peerAddr6 = bgpPeerAddr6; } else { });
                  }
                else
                  { }
              );
          })
        uplinkNames
    );
in
{
  inherit
    bgpSiteAsn
    bgpTopology
    routingMode
    siteControlPlaneCfg
    siteIpv6Cfg
    siteOverlays
    siteRouting
    siteTenantsCfg
    siteUplinksCfg
    uplinkRouting
    ;
}
