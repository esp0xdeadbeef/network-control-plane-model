{ helpers, inventory }:

let
  inherit (helpers)
    ensureUniqueEntries
    optionalAttrs
    requireAttrs
    requireStringList
    sortedNames
    ;

  inventoryRoot = optionalAttrs inventory;
  endpointsRoot = optionalAttrs (inventoryRoot.endpoints or null);

  buildFamilyIndex = familyName:
    ensureUniqueEntries
      "inventory.endpoints.*.${familyName}"
      (
        builtins.concatLists (
          builtins.map
            (endpointName:
              let
                endpointPath = "inventory.endpoints.${endpointName}";
                endpoint = requireAttrs endpointPath endpointsRoot.${endpointName};
                addresses =
                  if builtins.isList (endpoint.${familyName} or null) then
                    requireStringList "${endpointPath}.${familyName}" endpoint.${familyName}
                  else
                    [ ];
              in
              builtins.map
                (address: {
                  name = address;
                  value = {
                    endpoint = endpointName;
                    family = familyName;
                  };
                })
                addresses)
            (sortedNames endpointsRoot)
        )
      );
in
{
  byIPv4 = buildFamilyIndex "ipv4";
  byIPv6 = buildFamilyIndex "ipv6";
}
