# Canonical overlay records, published by the producer.
#
# WHY THIS IS ONE COLLECTION AND NOT A PROVIDER-NAMED ONE
# -------------------------------------------------------
# Overlay facts used to be split in two by the *provider* that happens to carry
# them: `canonicalSites` published the topology (which overlays exist, which nodes
# terminate them, bootstrap DNS), and `canonicalWireGuard` published the provider
# material (the interface and the provider contract) under a name that only makes
# sense if the transport is WireGuard.
#
# That is the wrong axis. `network-renderer-nixos` README states the rule this
# broke: a renderer must not "treat a provider name such as `nebula`, `wireguard`,
# or `openvpn` as generic forwarding truth". A canonical collection named after a
# provider is that mistake one layer up -- the model itself asserting that the
# overlay IS the provider.
#
# This publishes one record per overlay, with the provider as a FIELD:
#
#   { enterprise, site, overlay, provider, terminateOn, nodes,
#     providerBootstrapDns, providerInterface, providerContract, facts }
#
# `facts` is the complete modelled overlay record, published rather than
# re-derived, so a renderer that needs a field this projection does not single out
# can take it from here.
#
# WHERE THE FACTS COME FROM
# -------------------------
# One source: the overlay record the model publishes
# (`cpm.data.<enterprise>.<site>.overlays.<name>`), which already carries the
# topology AND the provider material -- `provider`, `providerContract` and
# `runtimeNodes` are fields on it because the producer merged the inventory into
# the forwarding model's overlay output. Nothing here reads the inventory.
#
# That is the correction this collection makes. The provider-named projection it
# replaces read `inventory.controlPlane.sites.<enterprise>.<site>.overlays`, a
# different path that is empty whenever the overlays live where the forwarding
# model puts them (measured on the provider-overlay example: `wgInventory` was
# `{}` while the overlay record carried the contract and the runtime nodes). So
# the old collection did not merely have a provider's name -- for that shape it
# published nothing at all, and a renderer consuming it silently rendered an
# empty overlay.
#
# The provider name is taken from the overlay record when the producer publishes
# one, and otherwise from the only provider the producer currently emits. When a
# second provider exists, this is the one place that has to change: `provider` is
# already a value on every record, so no consumer has to be renamed.
{ lib }:
cpm:
let
  # The provider is a value the model states, not a namespace this file invents.
  # The fallback exists because an overlay record that names no provider still has
  # one mechanism behind it; it is the only provider the producer emits today.
  providerOf = overlay: overlay.provider or "wireguard";

  # The interface a provider terminates on: the first non-empty
  # `runtimeNodes.<node>.service.interface` on the overlay. Same expression the
  # provider-named projection used, read from the overlay record instead of from a
  # separate inventory walk.
  providerInterfaceOf =
    overlay:
    let
      nodes = builtins.attrValues (overlay.runtimeNodes or { });
      interfaces = builtins.filter (s: builtins.isString s && s != "") (
        map (node: (node.service or { }).interface or null) nodes
      );
    in
    if interfaces == [ ] then null else builtins.head interfaces;

  entries = builtins.concatMap
    (
      enterprise:
      let
        sites = (cpm.data or { }).${enterprise} or { };
      in
      builtins.concatMap
        (
          site:
          let
            overlays = (sites.${site}.overlays or { });
          in
          map
            (
              overlayName:
              let
                overlay = overlays.${overlayName};
              in
              {
                inherit enterprise site;
                overlay = overlayName;
                provider = providerOf overlay;
                terminateOn = overlay.terminateOn or [ ];
                nodes = overlay.nodes or { };
                providerBootstrapDns = overlay.providerBootstrapDns or [ ];
                providerInterface = providerInterfaceOf overlay;
                providerContract = overlay.providerContract or null;
                facts = overlay;
              }
            )
            (builtins.attrNames overlays)
        )
        (builtins.attrNames sites)
    )
    (builtins.attrNames (cpm.data or { }));

  keyOf = entry: "${entry.enterprise}/${entry.site}/${entry.overlay}";

  # One entry per (enterprise, site, overlay). The provider material is global per
  # overlay name in the producer, so two sites naming one overlay share it; that is
  # a property of the inventory, not something this projection can resolve.
  overlays = builtins.sort (a: b: keyOf a < keyOf b) entries;

  # The same records keyed by overlay name, which is the access pattern the
  # overlay renderers use. A duplicate overlay name across sites keeps the first
  # record: the provider material is identical, and the topology for a specific
  # site is available in `overlays` above.
  byOverlay = builtins.listToAttrs (
    map
      (entry: {
        name = entry.overlay;
        value = {
          inherit (entry)
            provider
            providerInterface
            providerContract
            terminateOn
            nodes
            providerBootstrapDns
            ;
        };
      })
      overlays
  );
in
{
  inherit overlays byOverlay;
}
