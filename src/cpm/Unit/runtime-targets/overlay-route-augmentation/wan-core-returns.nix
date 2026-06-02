{ lib
, common
, helpers
, overlayProvisioning
, p2pPeerAddress
,
}:
let
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;
  inherit (helpers) isNonEmptyString;

  peerReturnPrefixes =
    lib.unique (
      lib.concatMap
        (
          overlayName:
          (listOrEmpty (overlayProvisioning.${overlayName}.peerTenantPrefixes or null))
          ++ (listOrEmpty (overlayProvisioning.${overlayName}.peerRuntimeRoutedPrefixes or null))
        )
        (builtins.attrNames overlayProvisioning)
    );

  returnRoutesVia =
    family: via:
    let
      viaField = if family == 4 then "via4" else "via6";
    in
    if !isNonEmptyString via then
      [ ]
    else
      builtins.map
        (prefix:
        let
          isRuntimePrefix = isNonEmptyString (prefix.sourceFile or null);
        in
        {
          inherit family;
          proto = "internal";
          tenant = prefix.tenantName or prefix.tenant or null;
          intent = {
            kind = if isRuntimePrefix then "runtime-routed-prefix-return" else "overlay-reachability";
            source = if isRuntimePrefix then "intent-routed-prefix" else "peer-tenant-prefix";
          };
          ${viaField} = via;
        }
        // (if isNonEmptyString (prefix.dst or null) then { inherit (prefix) dst; } else { })
        // (if isNonEmptyString (prefix.sourceFile or null) then { inherit (prefix) sourceFile; } else { })
        // (if isNonEmptyString (prefix.overlay or null) then { inherit (prefix) overlay; } else { })
        // (if isNonEmptyString (prefix.peerSite or null) then { inherit (prefix) peerSite; } else { }))
        (
          builtins.filter
            (prefix: (prefix.family or null) == family && isNonEmptyString (prefix.dst or prefix.sourceFile or null))
            peerReturnPrefixes
        );
in
nodeRole: interfaces:
if nodeRole != "core" then
  interfaces
else
  lib.mapAttrs
    (_: iface:
    let
      lane = ((iface.backingRef or { }).lane or { });
      routes = attrsOrEmpty (iface.routes or null);
      extraRoutes = {
        ipv4 = returnRoutesVia 4 (p2pPeerAddress 4 (iface.addr4 or null));
        ipv6 = returnRoutesVia 6 (p2pPeerAddress 6 (iface.addr6 or null));
      };
    in
    if
      (iface.sourceKind or null) != "p2p"
      || (lane.kind or null) != "uplink"
      || (lane.uplink or null) != "wan"
        || extraRoutes.ipv6 == [ ]
    then
      iface
    else
      iface // { routes = mergeRoutes routes extraRoutes; })
    interfaces
