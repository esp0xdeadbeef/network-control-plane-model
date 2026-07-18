{ helpers
, common
, inventoryEndpoints
, nodes
, serviceDefinitions
,
}:

let
  inherit (helpers) requireStringList;
  inherit (common) attrsOrEmpty failInventory;

  uniqueStrings =
    list:
    builtins.foldl'
      (
        acc: value:
        if builtins.isString value && value != "" && !(builtins.elem value acc) then acc ++ [ value ] else acc
      )
      [ ]
      list;

  stripPrefixLength = value:
    if !(builtins.isString value) || value == "" then
      ""
    else
      builtins.head (builtins.match "([^/]+)/.*" value);

  modeledEndpointAddresses = serviceName: providerName:
    let
      service = attrsOrEmpty (serviceDefinitions.${serviceName} or null);
      providerNode = service.providerNode or providerName;
      node = attrsOrEmpty (nodes.${providerNode} or null);
      loopback = attrsOrEmpty (node.loopback or null);
      modelAllocated = (service.addressAuthority or null) == "model-allocated-service-prefix";
      ipv4 = if modelAllocated then uniqueStrings [ (stripPrefixLength (loopback.ipv4 or "")) ] else [ ];
      ipv6 = if modelAllocated then uniqueStrings [ (stripPrefixLength (loopback.ipv6 or "")) ] else [ ];
    in
    {
      inherit ipv4 ipv6;
      addresses = uniqueStrings (ipv4 ++ ipv6);
      endpoint = if modelAllocated then node else { };
      endpointPath = "${serviceName}.providerNode.${providerNode}.loopback";
    };

  endpointAddresses =
    serviceName: providerName:
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
      explicit = {
        inherit endpoint endpointPath ipv4 ipv6;
        addresses = uniqueStrings (ipv4 ++ ipv6);
      };
    in
    if explicit.addresses != [ ] then explicit else modeledEndpointAddresses serviceName providerName;

  providerAddressesForDnsService =
    serviceName: providerName:
    let
      resolved = endpointAddresses serviceName providerName;
    in
    if resolved.endpoint == { } then
      failInventory
        resolved.endpointPath
        "DNS service provider '${providerName}' requires explicit inventory.endpoints.${providerName}.ipv4 and/or ipv6 for policy-derived DNS upstreams"
    else
      resolved.addresses;

  optionalProviderAddressesForDnsService =
    serviceName: providerName:
    (endpointAddresses serviceName providerName).addresses;

  providerEndpointForServiceProvider =
    serviceName: providerName:
    let
      resolved = endpointAddresses serviceName providerName;
    in
    if resolved.endpoint == { } || resolved.addresses == [ ] then
      null
    else
      {
        name = providerName;
        inherit (resolved) ipv4 ipv6;
      };
in
{
  inherit optionalProviderAddressesForDnsService providerAddressesForDnsService providerEndpointForServiceProvider;
}
