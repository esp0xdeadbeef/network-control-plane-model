{
  helpers,
  common,
  inventoryAttrs,
  enterpriseName,
  siteName,
  uplinkNames,
}:

let
  inherit (helpers)
    isNonEmptyString
    requireList
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
  siteIpv6Cfg = attrsOrEmpty (siteControlPlaneCfg.ipv6 or null);

  routingMode =
    let
      v = siteRouting.mode or "static";
    in
    if v == "bgp" || v == "static" then v else "static";

  bgpSite =
    if routingMode == "bgp" then
      attrsOrEmpty (siteRouting.bgp or null)
    else
      { };

  bgpSiteAsn = bgpSite.asn or null;
  bgpTopology = bgpSite.topology or "policy-rr";

  normalizeEgressMode = v:
    if v == "static" || v == "bgp" then v else "static";

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
                        ipv4 = requireList "${uplinkPath}.static.routes.ipv4" (staticRoutes.ipv4 or [ ]);
                        ipv6 = requireList "${uplinkPath}.static.routes.ipv6" (staticRoutes.ipv6 or [ ]);
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
