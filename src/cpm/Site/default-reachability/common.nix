{ helpers }:

let
  inherit (helpers) isNonEmptyString;

  makeStringSet = values:
    builtins.listToAttrs (
      builtins.map
        (value: {
          name = value;
          value = true;
        })
        values
    );

  commonLib = import ../../ControlModule/lib/common.nix { inherit helpers; };
  inherit (commonLib)
    attrsOrEmpty
    listOrEmpty
    mergeRoutes
    uniqueStrings
    ;

  uplinkNameFromAdjacencyId =
    adjacencyId:
    let
      marker = "--uplink-";
      parts = builtins.filter isNonEmptyString (builtins.split marker adjacencyId);
    in
    if builtins.length parts < 2 then
      null
    else
      builtins.elemAt parts ((builtins.length parts) - 1);

  accessNodeNameFromAdjacencyId =
    adjacencyId:
    let
      match = builtins.match ".*--access-(.+)--uplink-.*" adjacencyId;
    in
    if match == null then null else builtins.elemAt match 0;

  overlayNameFromInterfaceName =
    interfaceName:
    let
      match = builtins.match "overlay-(.+)" interfaceName;
    in
    if match == null then null else builtins.elemAt match 0;

  defaultDst = family:
    if family == 4 then "0.0.0.0/0" else "::/0";

  routeMatchesDefault = family: route:
    builtins.isAttrs route && (route.dst or null) == defaultDst family;

  routesContainDefault = family: routes:
    builtins.any (route: routeMatchesDefault family route) (listOrEmpty routes);

  stripDefaultRoutes = family: routes:
    builtins.filter (route: !(routeMatchesDefault family route)) (listOrEmpty routes);

  listContains = expected: values:
    builtins.any (value: value == expected) (listOrEmpty values);

  buildWANDefaultRoute = family: {
    dst = defaultDst family;
    intent = {
      kind = "default-reachability";
      source = "wan";
    };
    proto = "upstream";
  };

  buildInternalDefaultRoute =
    family: sourceNode: via: metric:
    {
      dst = defaultDst family;
      intent = {
        kind = "default-reachability";
        source = "explicit-exit";
        exitNode = sourceNode;
      };
      proto = "internal";
      inherit metric;
    }
    // {
      ${if family == 4 then "via4" else "via6"} = via;
    };

  buildInternalEndpointRoute =
    family: destination: destinationNode: via:
    {
      dst = if family == 4 then "${destination}/32" else "${destination}/128";
      intent = {
        kind = "internal-reachability";
        source = "transit-endpoint";
        node = destinationNode;
      };
      proto = "internal";
    }
    // {
      ${if family == 4 then "via4" else "via6"} = via;
    };

  routeAlreadyPresent =
    family: routes: destination: via:
    builtins.any
      (route:
        builtins.isAttrs route
        && (route.dst or null) == (if family == 4 then "${destination}/32" else "${destination}/128")
        && (if family == 4 then (route.via4 or null) == via else (route.via6 or null) == via))
      (listOrEmpty routes);

in
{
  inherit
    accessNodeNameFromAdjacencyId
    attrsOrEmpty
    buildInternalDefaultRoute
    buildInternalEndpointRoute
    buildWANDefaultRoute
    defaultDst
    listContains
    listOrEmpty
    makeStringSet
    mergeRoutes
    overlayNameFromInterfaceName
    routeAlreadyPresent
    routesContainDefault
    stripDefaultRoutes
    uniqueStrings
    uplinkNameFromAdjacencyId
    ;
}
