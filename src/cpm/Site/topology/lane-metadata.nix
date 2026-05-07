{ helpers }:

let
  inherit (helpers) isNonEmptyString;

  attrsOrEmpty = value:
    if builtins.isAttrs value then value else { };

  listOrEmpty = value:
    if builtins.isList value then value else [ ];

  interfaceLane =
    iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
    in
    attrsOrEmpty (backingRef.lane or null);

  effectiveRouteLane =
    iface: route:
    let
      routeLane = attrsOrEmpty (route.lane or null);
    in
    if routeLane != { } then routeLane else interfaceLane iface;

  laneUplinks =
    lane:
    listOrEmpty (lane.uplinks or null)
    ++ (if isNonEmptyString (lane.uplink or null) then [ lane.uplink ] else [ ]);
in
{
  inherit
    effectiveRouteLane
    interfaceLane
    laneUplinks
    ;
}
