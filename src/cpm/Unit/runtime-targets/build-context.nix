{
  lib,
  helpers,
  common,
  sitePath,
  uplinkRouting,
  overlayProvisioning,
  attachments,
  routedPrefixesByTenant,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs sortedNames;
  inherit (common) attrsOrEmpty ipam;

  defaultPortBindings = {
    byLink = { };
    byLogicalInterface = { };
    byUplink = { };
    portDefs = { };
  };

  hasExplicitWANForUplink =
    nodeInterfaces: uplinkName:
    builtins.any (
      ifName:
      let
        iface = requireAttrs "${sitePath}.nodes[*].interfaces.${ifName}" nodeInterfaces.${ifName};
      in
      (iface.kind or null) == "wan" && (iface.upstream or null) == uplinkName
    ) (sortedNames nodeInterfaces);

  ebgpNeighborsForTarget =
    isBgpRouter: effectiveRuntimeInterfaces:
    if !isBgpRouter then
      [ ]
    else
      lib.concatMap (
        ifName:
        let
          iface = effectiveRuntimeInterfaces.${ifName};
          upstream = iface.upstream or null;
          uplinkCfg =
            if isNonEmptyString upstream && hasAttr upstream uplinkRouting then
              uplinkRouting.${upstream}
            else
              null;
          uplinkMode = if uplinkCfg == null then null else uplinkCfg.mode or null;
          uplinkBgp = if uplinkCfg == null then { } else attrsOrEmpty (uplinkCfg.bgp or null);
          peerAddr4 = uplinkBgp.peerAddr4 or null;
          peerAddr6 = uplinkBgp.peerAddr6 or null;
        in
        if (iface.sourceKind or null) != "wan" || uplinkMode != "bgp" then
          [ ]
        else
          [
            (
              {
                peer_name = "uplink-${upstream}";
                peer_kind = "external-uplink";
                uplink = upstream;
                peer_asn = uplinkBgp.peerAsn or null;
                update_source = iface.runtimeIfName or null;
                route_reflector_client = false;
              }
              // (if isNonEmptyString peerAddr4 then { peer_addr4 = peerAddr4; } else { })
              // (if isNonEmptyString peerAddr6 then { peer_addr6 = peerAddr6; } else { })
            )
          ]
      ) (sortedNames effectiveRuntimeInterfaces);

  addOverlayUnderlayEndpointRoutes = import ./overlay-route-augmentation.nix {
    inherit
      lib
      helpers
      common
      ipam
      overlayProvisioning
      attachments
      routedPrefixesByTenant
      ;
  };
  overlayNames = sortedNames overlayProvisioning;
  runtimeOriginEgress = import ./runtime-origin-egress.nix {
    inherit
      lib
      helpers
      common
      overlayNames
      ;
  };


in
{
  inherit
    defaultPortBindings
    hasExplicitWANForUplink
    ebgpNeighborsForTarget
    addOverlayUnderlayEndpointRoutes
    overlayNames
    runtimeOriginEgress
    ;
}
