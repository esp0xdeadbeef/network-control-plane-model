{
  helpers,
  common,
  inventoryEndpoints,
}:

let
  inherit (helpers) requireStringList;
  inherit (common) attrsOrEmpty failInventory uniqueStrings;

  endpointAddresses =
    providerName:
    let
      endpointPath = "inventory.endpoints.${providerName}";
      endpoint = attrsOrEmpty (inventoryEndpoints.${providerName} or null);
      ipv4 =
        if builtins.isList (endpoint.ipv4 or null) then
          requireStringList "${endpointPath}.ipv4" endpoint.ipv4
        else
          [ ];
      ipv6 =
        if builtins.isList (endpoint.ipv6 or null) then
          requireStringList "${endpointPath}.ipv6" endpoint.ipv6
        else
          [ ];
    in
    {
      inherit endpoint endpointPath ipv4 ipv6;
      addresses = uniqueStrings (ipv4 ++ ipv6);
    };

  providerAddressesForDnsService =
    providerName:
    let
      resolved = endpointAddresses providerName;
    in
    if resolved.endpoint == { } then
      failInventory
        resolved.endpointPath
        "DNS service provider '${providerName}' requires explicit inventory.endpoints.${providerName}.ipv4 and/or ipv6 for policy-derived DNS upstreams"
    else
      resolved.addresses;

  optionalProviderAddressesForDnsService =
    providerName:
    (endpointAddresses providerName).addresses;

  providerEndpointForServiceProvider =
    providerName:
    let
      resolved = endpointAddresses providerName;
    in
    {
      name = providerName;
      inherit (resolved) ipv4 ipv6;
    };
in
{
  inherit optionalProviderAddressesForDnsService providerAddressesForDnsService providerEndpointForServiceProvider;
}
