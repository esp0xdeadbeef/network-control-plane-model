{ lib, uniqueStrings, dnsServiceRouteSpecs, allowedRelations ? [ ] }:

let
  specsForService =
    serviceName:
    lib.filter (spec: (spec.serviceName or null) == serviceName) dnsServiceRouteSpecs;

  preferredUplinksForSpec =
    spec:
    if builtins.isList (spec.derivedPreferredUplinks or null) && spec.derivedPreferredUplinks != [ ] then
      spec.derivedPreferredUplinks
    else if builtins.isList (spec.preferredUplinks or null) then
      spec.preferredUplinks
    else
      [ ];

  externalSpecsForService = serviceName:
    builtins.map
      (relation: {
        relationId = relation.id or null;
        preferredUplinks = (relation.to or { }).uplinks or [ ];
      })
      (builtins.filter
        (relation:
          (relation.action or "allow") == "allow"
          && (relation.trafficType or null) == "dns"
          && ((relation.from or { }).kind or null) == "service"
          && ((relation.from or { }).name or null) == serviceName
          && ((relation.to or { }).kind or null) == "external")
        allowedRelations);

  allSpecsForService = serviceName: (specsForService serviceName) ++ (externalSpecsForService serviceName);
in
{
  preferredDnsUplinksForService =
    serviceName:
    uniqueStrings (lib.concatMap preferredUplinksForSpec (allSpecsForService serviceName));

  preferredDnsUplinksByRelationForService =
    serviceName:
    builtins.listToAttrs (
      lib.filter (entry: entry.name != null && entry.value != [ ]) (
        map
          (spec: {
            name = spec.relationId or null;
            value = uniqueStrings (preferredUplinksForSpec spec);
          })
          (allSpecsForService serviceName)
      )
    );
}
