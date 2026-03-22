# ./src/validate-transit.nix

{ lib }:

site:

let
  links = site.links or {};
  linkNames = lib.attrNamesSorted links;

  invalidLinks =
    builtins.filter
      (item: item != null)
      (
        builtins.map
          (linkName:
            let
              link = links.${linkName};
              kind = link.kind or null;
            in
            if builtins.isAttrs link && kind != "p2p" then
              {
                name = linkName;
                kind = kind;
              }
            else
              null
          )
          linkNames
      );
in
if invalidLinks == [] then
  null
else
  throw ''
    control_plane_model transit derivation only supports p2p links when site.transit is not provided.
    Unsupported links:
    ${builtins.toJSON invalidLinks}
  ''
