# Canonical overlay/site facts, published by the producer.
#
# WHY
# ---
# `network-renderer-wireguard` and `network-renderer-nebula` build their node
# configuration from the producer's site tree (`control_plane.data`): which
# overlays exist, which nodes terminate them, their bootstrap DNS and node
# addresses. That is a dependency on the plain control-plane model, which
# RR_RAW_CPM_INPUT forbids.
#
# Their narrow slices (interfaces, routes, WireGuard providers) are not enough:
# the builders need the overlay topology itself. This publishes exactly those
# facts, in one flat deterministic list, so an overlay renderer can consume
# canonical content instead of walking the model:
#
#   { enterprise, site, overlay, terminateOn, nodes, providerBootstrapDns }
#
# It is a projection of the producer's own values -- nothing is re-derived, so it
# cannot disagree with the inventory they came from.
{ lib }:
cpm:
let
  enterpriseNames = builtins.attrNames (cpm.data or { });

  overlayEntries = builtins.concatMap
    (enterprise:
      let sites = cpm.data.${enterprise} or { }; in
      builtins.concatMap
        (site:
          let overlays = (cpm.data.${enterprise}.${site}.overlays or { }); in
          map
            (overlayName:
              let
                overlay = overlays.${overlayName};
                nodes = overlay.nodes or { };
              in
              {
                inherit enterprise site;
                overlay = overlayName;
                terminateOn = overlay.terminateOn or [ ];
                inherit nodes;
                providerBootstrapDns = overlay.providerBootstrapDns or [ ];
              })
            (builtins.attrNames overlays))
        (builtins.attrNames sites))
    enterpriseNames;

  keyOf = entry: "${entry.enterprise}/${entry.site}/${entry.overlay}";
in
{
  overlays = builtins.sort
    (a: b: (keyOf a) < (keyOf b))
    (builtins.attrValues (
      builtins.listToAttrs (map (entry: { name = keyOf entry; value = entry; }) overlayEntries)
    ));
}
