{
  lib,
  helpers,
  common,
  allowedRelations,
  serviceDefinitions,
  providerEndpointForServiceProvider,
}:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty;

  relationUplinks =
    relation:
    let from = attrsOrEmpty (relation.from or null);
    in
    if builtins.isList (from.uplinks or null) then
      from.uplinks
    else if isNonEmptyString (from.name or null) then
      [ from.name ]
    else
      [ ];

  serviceIngressRelations =
    builtins.filter
      (relation:
        let
          attrs = attrsOrEmpty relation;
          from = attrsOrEmpty (attrs.from or null);
          to = attrsOrEmpty (attrs.to or null);
        in
        (attrs.action or "allow") == "allow"
        && (from.kind or null) == "external"
        && relationUplinks attrs != [ ]
        && (to.kind or null) == "service"
        && isNonEmptyString (to.name or null)
        && attrsOrEmpty (serviceDefinitions.${to.name} or null) != { })
      allowedRelations;

  endpointAddressesForService =
    serviceName:
    lib.concatMap
      (provider:
        let endpoint = providerEndpointForServiceProvider provider;
        in
        (endpoint.ipv4 or [ ]) ++ (endpoint.ipv6 or [ ]))
      (listOrEmpty ((serviceDefinitions.${serviceName} or { }).providers or null));

in
{
  inherit
    endpointAddressesForService
    relationUplinks
    serviceIngressRelations
    ;
}
