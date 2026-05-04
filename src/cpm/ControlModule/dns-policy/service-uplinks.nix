{ lib, uniqueStrings, dnsServiceRouteSpecs }:

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
in
{
  preferredDnsUplinksForService =
    serviceName:
    uniqueStrings (lib.concatMap preferredUplinksForSpec (specsForService serviceName));

  preferredDnsUplinksByRelationForService =
    serviceName:
    builtins.listToAttrs (
      lib.filter (entry: entry.name != null && entry.value != [ ]) (
        map (spec: {
          name = spec.relationId or null;
          value = uniqueStrings (preferredUplinksForSpec spec);
        }) (specsForService serviceName)
      )
    );
}
