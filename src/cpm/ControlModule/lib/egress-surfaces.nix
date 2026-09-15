{ lib }:

# FS-322 Scope Reachability / FS-370 Source Prefix Binding to Exit.
#
# A permission relation names only what is allowed and never names an uplink,
# interface, or address (FS-322). The egress surface of an external relation is
# the *selected exit* the from-scope declares in its `selects`; "egress surface"
# is only an informal alias for that selected exit and is not a separate modeled
# object (URS 39, FS-370).
#
# A relation may still carry a legacy pin (`to.uplinks`/`to.scope`/`to.name`);
# when present it is honored, otherwise the surfaces are resolved from the
# selecting scope's `selects`. The resolved surface names are the uplink/exit
# surface names the selected scope owns.

let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];

  uniqueStrings =
    list:
    builtins.foldl'
      (
        acc: value:
        if builtins.isString value && value != "" && !(builtins.elem value acc) then acc ++ [ value ] else acc
      )
      [ ]
      list;

  endpointTenants =
    endpoint:
    if !(builtins.isAttrs endpoint) then
      [ ]
    else if (endpoint.kind or null) == "tenant" then
      [ (endpoint.name or null) ]
    else if (endpoint.kind or null) == "tenant-set" then
      listOrEmpty (endpoint.members or null)
    else
      [ ];

  # The explicit pin a relation may still carry (or an ingress endpoint).
  pinnedSurfaces =
    endpoint:
    if !(builtins.isAttrs endpoint) then
      [ ]
    else if (endpoint.kind or null) != "external" then
      [ ]
    else if builtins.isList (endpoint.uplinks or null) then
      uniqueStrings (endpoint.uplinks or [ ])
    else if builtins.isString (endpoint.scope or null) && endpoint.scope != "" then
      [ endpoint.scope ]
    else if builtins.isString (endpoint.name or null) && endpoint.name != "" then
      [ endpoint.name ]
    else
      [ ];

  # The exit surfaces a scope declares in `selects`, using the declared surface
  # name when present and falling back to the owning selected scope.
  selectsSurfaces =
    node:
    uniqueStrings (
      map
        (
          entry:
          if builtins.isAttrs entry then
            (entry.surface or entry.scope or entry.uplink or null)
          else if builtins.isString entry then
            entry
          else
            null
        )
        (listOrEmpty (node.selects or null))
    );

  # Surfaces for a from-endpoint: the access scope(s) that attach its tenants
  # declare the reachability in `selects`.
  surfacesForEndpoint =
    nodes: endpoint:
    let
      tenants = endpointTenants endpoint;
      matching = lib.filter
        (
          nodeName:
          builtins.any
            (
              a: (a.kind or null) == "tenant" && builtins.elem (a.name or null) tenants
            )
            (listOrEmpty ((attrsOrEmpty (nodes.${nodeName} or null)).attachments or null))
        )
        (builtins.attrNames nodes);
    in
    uniqueStrings (lib.concatMap (nodeName: selectsSurfaces (attrsOrEmpty nodes.${nodeName} or { })) matching);
in
{
  inherit pinnedSurfaces selectsSurfaces surfacesForEndpoint;

  # Resolve the egress surfaces for a relation's external destination:
  # an explicit relation pin wins, otherwise the from-scope's `selects`.
  relationEgressSurfaces =
    nodes: relation:
    let
      to = relation.to or { };
      pinned = pinnedSurfaces to;
    in
    if pinned != [ ] then pinned else surfacesForEndpoint nodes (relation.from or { });
}
