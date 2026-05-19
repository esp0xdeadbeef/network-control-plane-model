{
  lib,
  common,
  helpers,
  overlayProvisioning,
  p2pPeerAddress,
}:
let
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;
  inherit (helpers) isNonEmptyString;

  peerRuntimePrefixes =
    lib.unique (
      lib.concatMap
        (overlayName: listOrEmpty (overlayProvisioning.${overlayName}.peerRuntimeRoutedPrefixes or null))
        (builtins.attrNames overlayProvisioning)
    );

  returnRoutesVia =
    via:
    if !isNonEmptyString via then
      [ ]
    else
      builtins.map
        (prefix:
          prefix
          // {
            proto = "internal";
            intent = {
              kind = "runtime-routed-prefix-return";
              source = "intent-routed-prefix";
            };
            via6 = via;
          })
        peerRuntimePrefixes;
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
          ipv4 = [ ];
          ipv6 = returnRoutesVia (p2pPeerAddress 6 (iface.addr6 or null));
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
