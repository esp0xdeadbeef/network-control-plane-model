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
                # The complete modelled overlay record, published rather than
                # re-derived: a renderer that needs a field this projection does
                # not single out (nebula's overlay plan reads peers, lighthouses
                # and static hosts) can take it from here instead of walking the
                # producer's model.
                facts = overlay;
              })
            (builtins.attrNames overlays))
        (builtins.attrNames sites))
    enterpriseNames;

  keyOf = entry: "${entry.enterprise}/${entry.site}/${entry.overlay}";
  # Site-level records: the plan derives dynamic firewall CIDRs from
  # `site.domains.tenants`, which lives on the site, not on an overlay or a
  # target. Published as canonical content so an overlay renderer does not have
  # to walk the producer's model for it.
  siteEntries = builtins.concatMap
    (enterprise:
      let sites = cpm.data.${enterprise} or { }; in
      map
        (site: {
          inherit enterprise site;
          facts = sites.${site};
        })
        (builtins.attrNames sites))
    enterpriseNames;

  siteKeyOf = entry: "${entry.enterprise}/${entry.site}";

  # The same site facts, grouped the way the producer's own `data` tree is grouped:
  # enterprise -> site -> record.
  #
  # `sites` above is a flat list, which is the right shape for a renderer that wants
  # "every site record". It is the wrong shape for the consumers that iterate
  # enterprise -> site, and there are several: network-renderer-nixos
  # dry-config-model/sites.nix and its Unit/lookup/runtime-context files walk
  # exactly that tree, so they read `control_plane_model.data` -- which
  # RR_RAW_CPM_INPUT forbids. Regrouping the flat list in each consumer is both
  # repetitive and easy to get subtly wrong (measured: one such regroup cost 10
  # tests); the producer already holds this grouping, so it publishes it here.
  #
  # This is a projection of values the model already carries. Nothing is
  # re-derived and no entry is added that `sites` does not also contain.
  byEnterprise =
    builtins.foldl'
      (
        acc: entry:
        acc
        // {
          ${entry.enterprise} = (acc.${entry.enterprise} or { }) // {
            ${entry.site} = entry.facts;
          };
        }
      )
      { }
      siteEntries;
in
{
  inherit byEnterprise;
  sites = builtins.sort
    (a: b: (siteKeyOf a) < (siteKeyOf b))
    (builtins.attrValues (
      builtins.listToAttrs (map (entry: { name = siteKeyOf entry; value = entry; }) siteEntries)
    ));
  overlays = builtins.sort
    (a: b: (keyOf a) < (keyOf b))
    (builtins.attrValues (
      builtins.listToAttrs (map (entry: { name = keyOf entry; value = entry; }) overlayEntries)
    ));
}
