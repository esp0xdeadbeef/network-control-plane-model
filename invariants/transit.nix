{ lib, common }:

let
  inherit (common)
    fail
    forceAll
    hasAttr
    hasDuplicates
    isNonEmptyString
    requireAttrs
    requireList
    ;

  validateTransitEndpoint = context: adjacencyIndex: endpointIndex: endpoint:
    let prefix = "transit.adjacencies[${toString adjacencyIndex}].endpoints[${toString endpointIndex}]";
    in
    if !builtins.isAttrs endpoint then
      fail context "${prefix} must be an attribute set"
    else if !isNonEmptyString (endpoint.unit or null) then
      fail context "${prefix}.unit is required"
    else if !(endpoint ? local) then
      fail context "${prefix}.local is required"
    else if !builtins.isAttrs endpoint.local then
      fail context "${prefix}.local must be an attribute set"
    else if !(isNonEmptyString (endpoint.local.ipv4 or null) || isNonEmptyString (endpoint.local.ipv6 or null)) then
      fail context "${prefix}.local must contain ipv4 or ipv6"
    else
      true;

  validateAdjacency = context: links: adjacencyIndex: adjacency:
    let
      prefix = "transit.adjacencies[${toString adjacencyIndex}]";
      adjacencyAttrs =
        if builtins.isAttrs adjacency then adjacency else fail context "${prefix} must be an attribute set";
      adjacencyId = adjacencyAttrs.id or null;
      kind = adjacencyAttrs.kind or null;
      linkName = adjacencyAttrs.link or null;
      endpoints =
        if adjacencyAttrs ? endpoints then adjacencyAttrs.endpoints else fail context "${prefix}.endpoints is required";
    in
    if !isNonEmptyString adjacencyId then
      fail context "${prefix}.id is required"
    else if !isNonEmptyString kind then
      fail context "${prefix}.kind is required"
    else if !builtins.isList endpoints then
      fail context "${prefix}.endpoints must be a list"
    else if builtins.length endpoints != 2 then
      fail context "${prefix}.endpoints must contain exactly 2 endpoints"
    else if kind == "p2p" && !isNonEmptyString linkName then
      fail context "${prefix}.link is required for p2p adjacency"
    else if kind == "p2p" && !(hasAttr linkName links) then
      fail context "${prefix}.link references unknown link '${linkName}'"
    else if kind == "p2p" then
      let linkId = links.${linkName}.id or null;
      in
      if !isNonEmptyString linkId then
        fail context "links.${linkName}.id is required"
      else if linkId != adjacencyId then
        fail context "transit adjacency id '${adjacencyId}' does not match links.${linkName}.id '${linkId}'"
      else
        validateEndpoints context adjacencyIndex endpoints
    else
      validateEndpoints context adjacencyIndex endpoints;

  validateEndpoints =
    context: adjacencyIndex: endpoints:
    forceAll (
      builtins.genList
        (endpointIndex: validateTransitEndpoint context adjacencyIndex endpointIndex (builtins.elemAt endpoints endpointIndex))
        (builtins.length endpoints)
    );

in
{
  validate = context: links: transit:
    let
      transitAttrs = requireAttrs context "transit" transit;
      adjacencies = requireList context "transit.adjacencies" (transitAttrs.adjacencies or null);
      orderingRaw = transitAttrs.ordering or null;
      ordering =
        if !builtins.isList orderingRaw then
          fail context "transit.ordering must be a list of stable adjacency IDs"
        else if !builtins.all isNonEmptyString orderingRaw then
          fail context "transit.ordering must contain only stable adjacency IDs"
        else
          orderingRaw;
      adjacencyIds =
        builtins.genList
          (adjacencyIndex:
            let adjacency = builtins.elemAt adjacencies adjacencyIndex;
            in
            if !builtins.isAttrs adjacency then
              fail context "transit.adjacencies[${toString adjacencyIndex}] must be an attribute set"
            else if !isNonEmptyString (adjacency.id or null) then
              fail context "transit.adjacencies[${toString adjacencyIndex}].id is required"
            else
              adjacency.id)
          (builtins.length adjacencies);
      adjacencyIdSet = builtins.listToAttrs (map (id: { name = id; value = true; }) adjacencyIds);
      p2pIds =
        builtins.filter
          (id: id != null)
          (builtins.genList
            (adjacencyIndex:
              let adjacency = builtins.elemAt adjacencies adjacencyIndex;
              in if builtins.isAttrs adjacency && (adjacency.kind or null) == "p2p" then adjacency.id or null else null)
            (builtins.length adjacencies));
    in
    builtins.seq
      (forceAll (
        builtins.map
          (linkName:
            let link = links.${linkName};
            in
            if !builtins.isAttrs link then
              fail context "links.${linkName} must be an attribute set"
            else if !isNonEmptyString (link.id or null) then
              fail context "links.${linkName}.id is required"
            else
              true)
          (lib.attrNamesSorted links)
      ))
      (builtins.seq
        (if hasDuplicates adjacencyIds then fail context "transit.adjacencies contains duplicate ids" else true)
        (builtins.seq
          (if hasDuplicates ordering then fail context "transit.ordering contains duplicate adjacency IDs" else true)
          (builtins.seq
            (forceAll (builtins.genList (idx: validateAdjacency context links idx (builtins.elemAt adjacencies idx)) (builtins.length adjacencies)))
            (builtins.seq
              (forceAll (
                builtins.genList
                  (idx:
                    let entry = builtins.elemAt ordering idx;
                    in if hasAttr entry adjacencyIdSet then true else fail context "transit.ordering[${toString idx}] references unknown adjacency ID '${entry}'")
                  (builtins.length ordering)
              ))
              (forceAll (
                builtins.map
                  (adjacencyId:
                    if builtins.elem adjacencyId ordering then
                      true
                    else
                      fail context "p2p adjacency '${adjacencyId}' is missing from transit.ordering")
                  p2pIds
              ))))));
}
