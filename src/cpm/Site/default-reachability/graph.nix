{
  helpers,
  common,
  sitePath,
  transit,
}:

let
  inherit (helpers) hasAttr requireList requireString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty makeStringSet uniqueStrings;

  addNeighbor = acc: nodeName: neighborRecord:
    let
      existing = if hasAttr nodeName acc then acc.${nodeName} else [ ];
    in
    acc // { ${nodeName} = existing ++ [ neighborRecord ]; };

  neighborMap =
    builtins.foldl'
      (acc: adjacency:
        let
          adjacencyId = requireString "${sitePath}.transit.adjacencies[*].id" (adjacency.id or null);
          endpoints = requireList "${sitePath}.transit.adjacencies[*].endpoints" (adjacency.endpoints or null);
          laneMeta = attrsOrEmpty (adjacency.laneMeta or null);
          left = builtins.elemAt endpoints 0;
          right = builtins.elemAt endpoints 1;
          leftNode = requireString "${sitePath}.transit.adjacencies[*].endpoints[0].unit" (left.unit or null);
          rightNode = requireString "${sitePath}.transit.adjacencies[*].endpoints[1].unit" (right.unit or null);
          leftLocal = attrsOrEmpty (left.local or null);
          rightLocal = attrsOrEmpty (right.local or null);
          withLeft = addNeighbor acc leftNode {
            adjacencyId = adjacencyId;
            inherit laneMeta;
            neighbor = rightNode;
            via4 = rightLocal.ipv4 or null;
            via6 = rightLocal.ipv6 or null;
          };
        in
        addNeighbor withLeft rightNode {
          adjacencyId = adjacencyId;
          inherit laneMeta;
          neighbor = leftNode;
          via4 = leftLocal.ipv4 or null;
          via6 = leftLocal.ipv6 or null;
        })
      { }
      (listOrEmpty (transit.adjacencies or null));

  addTransitEndpointAddress = acc: nodeName: family: address:
    let
      existing = if hasAttr nodeName acc then acc.${nodeName} else { ipv4 = [ ]; ipv6 = [ ]; };
    in
    acc
    // {
      ${nodeName} = {
        ipv4 = if family == 4 then uniqueStrings (existing.ipv4 ++ [ address ]) else existing.ipv4;
        ipv6 = if family == 6 then uniqueStrings (existing.ipv6 ++ [ address ]) else existing.ipv6;
      };
    };

  transitEndpointAddressesByNode =
    builtins.foldl'
      (acc: adjacency:
        let
          endpoints = requireList "${sitePath}.transit.adjacencies[*].endpoints" (adjacency.endpoints or null);
          applyEndpoint =
            state: endpoint:
            let
              nodeName = requireString "${sitePath}.transit.adjacencies[*].endpoints[*].unit" (endpoint.unit or null);
              local = attrsOrEmpty (endpoint.local or null);
              state4 =
                if helpers.isNonEmptyString (local.ipv4 or null) then
                  addTransitEndpointAddress state nodeName 4 local.ipv4
                else
                  state;
            in
            if helpers.isNonEmptyString (local.ipv6 or null) then
              addTransitEndpointAddress state4 nodeName 6 local.ipv6
            else
              state4;
        in
        builtins.foldl' applyEndpoint acc endpoints)
      { }
      (listOrEmpty (transit.adjacencies or null));

  findCandidatePaths = family: sourceSet: nodeName: visited:
    if hasAttr nodeName sourceSet then
      [ { sourceNode = nodeName; steps = [ ]; } ]
    else
      let
        neighbors = if hasAttr nodeName neighborMap then neighborMap.${nodeName} else [ ];
      in
      builtins.concatLists (
        builtins.map
          (neighbor:
            let
              neighborNode = neighbor.neighbor;
              familyVia = if family == 4 then neighbor.via4 or null else neighbor.via6 or null;
            in
            if hasAttr neighborNode visited || !helpers.isNonEmptyString familyVia then
              [ ]
            else
              builtins.map
                (subPath: {
                  sourceNode = subPath.sourceNode;
                  steps = [
                    {
                      adjacencyId = neighbor.adjacencyId;
                      laneMeta = neighbor.laneMeta;
                      via = familyVia;
                      nextHopNode = neighborNode;
                    }
                  ] ++ subPath.steps;
                })
                (findCandidatePaths family sourceSet neighborNode (visited // { ${nodeName} = true; })))
          neighbors
      );

  compareCandidatePaths =
    left: right:
    if builtins.length left.steps < builtins.length right.steps then
      true
    else if builtins.length left.steps > builtins.length right.steps then
      false
    else
      left.sourceNode < right.sourceNode;

  sortedCandidatePaths = family: sourceSet: nodeName:
    builtins.sort compareCandidatePaths (findCandidatePaths family sourceSet nodeName { });

in
{
  inherit
    makeStringSet
    sortedCandidatePaths
    transitEndpointAddressesByNode
    ;
}
