# ./src/build-cpm.nix

{ lib }:

enterprise:

let
  deriveTransit = import ./derive-transit.nix { inherit lib; };

  normalizeTransit = site:
    let
      transit = site.transit or null;
    in
    if builtins.isAttrs transit
      && builtins.isList (transit.adjacencies or null)
      && builtins.isList (transit.ordering or null)
    then
      transit
    else
      deriveTransit site;

in
{
  version = 1;
  source = "nix";

  data =
    lib.mapAttrsSorted
      (_: ent:
        lib.mapAttrsSorted
          (_: site: {
            transit = normalizeTransit site;
          })
          (ent.site or {})
      )
      enterprise;
}
