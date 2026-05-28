{
  common,
  endpointContext,
  familyRoutes,
  routeIntent,
  coreInterfacesFor,
  pairRules,
}:

let
  inherit (endpointContext)
    attrsOrEmpty
    uniqueStrings
    policyInterfaces
    accessNodesForLogicalNodeTenantAttachment
    runtimeLogicalNodesForExternal
    ;

  overlayTenantPolicyInterfacesFor =
    endpoint:
    let
      externalName = (attrsOrEmpty endpoint).name or null;
      accessNodes = uniqueStrings (
        builtins.concatLists (
          map accessNodesForLogicalNodeTenantAttachment (runtimeLogicalNodesForExternal externalName)
        )
      );
    in
    builtins.filter (iface: builtins.elem (common.laneAccess iface) accessNodes) policyInterfaces;

  hasOverlayUnderlayEndpointRoute =
    overlayName: iface:
    builtins.any (
      route:
      builtins.isAttrs route
      && (route.overlay or null) == overlayName
      && (route.proto or null) == "underlay"
      && ((routeIntent route).kind or null) == "overlay-underlay-reachability"
    ) (familyRoutes (attrsOrEmpty (iface.routes or null)));

in
relationRaw:
let
  relation = attrsOrEmpty relationRaw;
  fromExternal = attrsOrEmpty (relation.from or null);
  toExternal = attrsOrEmpty (relation.to or null);
  overlayName = fromExternal.name or null;
  fromIsNamedOverlay =
    (fromExternal.kind or null) == "external" && fromExternal ? name && !(fromExternal ? uplinks);
  toIsWanUplink =
    (toExternal.kind or null) == "external" && builtins.isList (toExternal.uplinks or null);
  toCores = builtins.filter (
    iface: overlayName != null && hasOverlayUnderlayEndpointRoute overlayName iface
  ) (coreInterfacesFor toExternal);
in
if
  (relation.action or "allow") != "allow"
  || (relation.trafficType or "any") == "any"
  || !fromIsNamedOverlay
  || !toIsWanUplink
then
  [ ]
else
  pairRules relation
    ((coreInterfacesFor fromExternal) ++ (overlayTenantPolicyInterfacesFor fromExternal))
    toCores
    {
      intent = {
        kind = "overlay-underlay-reachability";
        source = "overlay-underlay-endpoint";
        overlay = overlayName;
      };
    }
