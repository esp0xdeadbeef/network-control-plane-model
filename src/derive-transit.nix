{ lib }:

site:

let
  links = site.links or {};

  mkEndpoint = ep: {
    unit = ep.node or null;
    local = {
      ipv4 = lib.stripMask (ep.addr4 or null);
      ipv6 = lib.stripMask (ep.addr6 or null);
    };
  };

  mkAdjacency = link:
    let
      endpointNames = lib.attrNamesSorted (link.endpoints or {});

      endpoints =
        builtins.map
          (name: mkEndpoint link.endpoints.${name})
          endpointNames;
    in
    {
      endpoints = endpoints;
    };

  p2pLinks =
    lib.filter
      lib.isP2PLink
      (lib.attrValuesSorted links);

  adjacencies =
    builtins.map mkAdjacency p2pLinks;

  ordering =
    builtins.map
      (adj:
        builtins.map
          (ep: ep.unit)
          adj.endpoints
      )
      adjacencies;

in
{
  adjacencies = adjacencies;
  ordering = ordering;
}
