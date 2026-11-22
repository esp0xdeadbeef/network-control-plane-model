# Canonical WireGuard provider content, published by the producer.
#
# WHY
# ---
# `network-renderer-wireguard` builds its node configs from the producer model
# (`controlPlane.control_plane_model.wgInventory` / `.providerContracts`), which
# is exactly the dependency RR_RAW_CPM_INPUT forbids: the renderer would consume
# the CPM rather than canonical content.
#
# This publishes the same facts under an explicit canonical name so the renderer
# can take them from the validated bundle:
#
#   { providers = <overlay name -> WireGuard provider interface + peers>;
#     contracts = <overlay name -> provider contract> }
#
# It is a projection, not a re-derivation: the producer already owns these
# values, and re-computing them here would risk disagreeing with the inventory
# they came from.
{ lib }:
cpm:
let
  providers = cpm.wgInventory or { };
  # The renderer reads `providerContracts.wireguard` (the per-overlay WireGuard
  # provider contracts the producer builds from inventory), so the canonical
  # projection keeps that key rather than flattening it away.
  contracts = {
    wireguard = cpm.providerContractsWireguard or { };
  };
in
{
  inherit providers contracts;
}
