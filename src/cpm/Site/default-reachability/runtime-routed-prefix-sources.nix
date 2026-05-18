{
  helpers,
  common,
  siteAttrs,
  runtimeTargetsWithWANDefaultsByNode,
}:

let
  inherit (helpers) hasAttr sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;

  isRuntimeRoutedIPv6Prefix =
    routed:
    (routed.family or null) == "ipv6"
    && ((routed.allocation or null) == "runtime" || (routed.source or null) == "inventory-routed-prefix");

  runtimeRoutedIPv6PrefixesForTenant =
    tenantName:
    let
      tenant = attrsOrEmpty (siteAttrs.tenants.${tenantName} or null);
      resolvedRoutedPrefixes = attrsOrEmpty (siteAttrs.routedPrefixesByTenant or null);
      ownership = attrsOrEmpty (siteAttrs.ownership or null);
      ownershipPrefixes = listOrEmpty (ownership.prefixes or null);
      tenantOwnershipPrefixes =
        builtins.filter
          (prefix: (attrsOrEmpty prefix).name or null == tenantName)
          ownershipPrefixes;
      routedEntries =
        (listOrEmpty (tenant.routedPrefixes or null))
        ++ (listOrEmpty (resolvedRoutedPrefixes.${tenantName} or null))
        ++ builtins.concatLists (builtins.map (prefix: listOrEmpty ((attrsOrEmpty prefix).routedPrefixes or null)) tenantOwnershipPrefixes);
    in
    builtins.filter isRuntimeRoutedIPv6Prefix routedEntries;

  ownsRuntimeRoutedIPv6Prefix =
    tenantName:
    builtins.any (_: true) (runtimeRoutedIPv6PrefixesForTenant tenantName);

  isRuntimeRoutedIPv6AccessNode =
    accessNodeName:
    hasAttr accessNodeName runtimeTargetsWithWANDefaultsByNode
    && (
      let
        target = runtimeTargetsWithWANDefaultsByNode.${accessNodeName}.target;
        networks = attrsOrEmpty (target.networks or null);
      in
      builtins.any
        (networkName:
          let network = attrsOrEmpty networks.${networkName};
          in
          (network.kind or null) == "tenant"
          && (
            ownsRuntimeRoutedIPv6Prefix networkName
            || builtins.any isRuntimeRoutedIPv6Prefix (listOrEmpty (network.routedPrefixes or null))
          ))
        (sortedNames networks)
    );

  runtimeRoutedIPv6PrefixesForAccessNode =
    accessNodeName:
    if !hasAttr accessNodeName runtimeTargetsWithWANDefaultsByNode then
      [ ]
    else
      let
        target = runtimeTargetsWithWANDefaultsByNode.${accessNodeName}.target;
        networks = attrsOrEmpty (target.networks or null);
      in
      builtins.concatLists (
        builtins.map
          (networkName:
            let
              network = attrsOrEmpty networks.${networkName};
              networkPrefixes = builtins.filter isRuntimeRoutedIPv6Prefix (listOrEmpty (network.routedPrefixes or null));
            in
            if (network.kind or null) != "tenant" then
              [ ]
            else
              runtimeRoutedIPv6PrefixesForTenant networkName ++ networkPrefixes)
          (sortedNames networks)
      );

  runtimeRoutedIPv6AccessNodeNames =
    builtins.filter isRuntimeRoutedIPv6AccessNode (sortedNames runtimeTargetsWithWANDefaultsByNode);

in
{
  inherit
    isRuntimeRoutedIPv6AccessNode
    runtimeRoutedIPv6AccessNodeNames
    ;
  isDelegatedIPv6AccessNode = isRuntimeRoutedIPv6AccessNode;
  runtimeRoutedIPv6PrefixesByAccessNode = builtins.listToAttrs (
    builtins.map
      (accessNodeName: {
        name = accessNodeName;
        value = runtimeRoutedIPv6PrefixesForAccessNode accessNodeName;
      })
      runtimeRoutedIPv6AccessNodeNames
  );
}
