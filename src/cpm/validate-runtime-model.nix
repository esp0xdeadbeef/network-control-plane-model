{ helpers }:

{ cpm }:

let
  inherit (helpers)
    requireAttrs
    sortedNames
    ;

  baseValidator =
    (import ../../invariants/default.nix {
      lib = {
        attrNamesSorted = sortedNames;
      };
    }).validateCPMData;

  cpmAttrs = requireAttrs "control_plane_model" cpm;
  data = requireAttrs "control_plane_model.data" (cpmAttrs.data or null);
in
baseValidator data
