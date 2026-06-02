{
  listOrEmpty,
  serviceNamesForEndpoint,
  serviceRecords,
  uniqueStrings,
}:

let
  cidrForServiceAddress =
    address:
    if !(builtins.isString address) || address == "" then
      null
    else if builtins.match ".*:.*" address != null then
      let
        match = builtins.match "([^:]+):([^:]+):([^:]+):([^:]+):.*" address;
      in
      if match != null then
        "${builtins.elemAt match 0}:${builtins.elemAt match 1}:${builtins.elemAt match 2}:${builtins.elemAt match 3}::/64"
      else
        null
    else
      let
        octets = builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)\\..*" address;
      in
      if octets != null then
        "${builtins.elemAt octets 0}.${builtins.elemAt octets 1}.${builtins.elemAt octets 2}.0/24"
      else
        null;

  familyForPrefix =
    prefix:
    if builtins.isString prefix && builtins.match ".*:.*" prefix != null then 6 else 4;
in
endpoint:
let
  serviceNames = serviceNamesForEndpoint endpoint;
  addresses =
    builtins.concatLists (
      map
        (
          serviceName:
          if !(builtins.hasAttr serviceName serviceRecords) then
            [ ]
          else
            builtins.concatLists (
              map
                (
                  provider:
                  listOrEmpty (provider.ipv4 or null) ++ listOrEmpty (provider.ipv6 or null)
                )
                (listOrEmpty (serviceRecords.${serviceName}.providerEndpoints or null))
            )
        )
        serviceNames
    );
  prefixes =
    uniqueStrings (
      builtins.filter (prefix: prefix != null) (map cidrForServiceAddress addresses)
    );
in
map (prefix: { family = familyForPrefix prefix; inherit prefix; }) prefixes
