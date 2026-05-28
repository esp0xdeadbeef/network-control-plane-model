{ helpers }:

{ sitePath
, siteAttrs
, runtimeTargets
, policyEndpointBindings ? { }
, services ? [ ]
,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs sortedNames;
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];
  uniqueStrings =
    values:
    sortedNames (
      builtins.listToAttrs (
        map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter isNonEmptyString values)
      )
    );

  communicationContract = attrsOrEmpty (siteAttrs.communicationContract or null);
  siteRelations =
    if builtins.isList (communicationContract.relations or null) then
      communicationContract.relations
    else
      listOrEmpty (communicationContract.allowedRelations or null);
  overlayNames = uniqueStrings (
    sortedNames (attrsOrEmpty (siteAttrs.overlays or null))
    ++ sortedNames (attrsOrEmpty (siteAttrs.overlayReachability or null))
    ++ map (overlay: overlay.name or null) (listOrEmpty ((attrsOrEmpty (siteAttrs.transport or null)).overlays or null))
  );

  runtimeInterfaceRecords = import ./firewall-intent/runtime-interfaces.nix { inherit helpers; };
  runtimeOriginSourcePrefixesForSite =
    import ./firewall-intent/runtime-origin-source-prefixes.nix { inherit helpers; };
  buildNat = import ./firewall-intent/nat.nix { inherit helpers; };
  buildForwarding = import ./firewall-intent/forwarding.nix { inherit helpers; };

  targetEntries = map
    (
      targetName:
      let
        targetPath = "${sitePath}.runtimeTargets.${targetName}";
        target = requireAttrs targetPath runtimeTargets.${targetName};
        interfaceRecords = runtimeInterfaceRecords targetPath target;
      in
      {
        inherit targetName target interfaceRecords;
      }
    )
    (sortedNames runtimeTargets);

  runtimeOriginSourcePrefixes = runtimeOriginSourcePrefixesForSite {
    inherit
      sitePath
      siteAttrs
      targetEntries
      ;
  };

  natEntries = builtins.filter (entry: entry != null) (
    map
      (
        entry:
        if (entry.target.role or null) == "core" then
          {
            name = entry.targetName;
            value = buildNat {
              inherit
                siteAttrs
                overlayNames
                ;
              inherit (entry) interfaceRecords target;
              inherit runtimeOriginSourcePrefixes;
            };
          }
        else
          null
      )
      targetEntries
  );

  forwardingEntries = builtins.filter (entry: entry != null) (
    map
      (
        entry:
        let
          value = buildForwarding {
            inherit
              overlayNames
              policyEndpointBindings
              services
              siteRelations
              runtimeOriginSourcePrefixes
              ;
            tenantPrefixOwners = attrsOrEmpty (siteAttrs.tenantPrefixOwners or null);
            inherit (entry) target interfaceRecords;
          };
        in
        if value == null then
          null
        else
          {
            name = entry.targetName;
            inherit value;
          }
      )
      targetEntries
  );

  precedence = import ./firewall-intent/precedence.nix { };
  sortedForwardingEntries = precedence.sortEntries forwardingEntries;
  assertNoShadowedPolicyDenies = precedence.assertNoShadowedPolicyDenies sortedForwardingEntries;
in
{
  natByTarget = builtins.listToAttrs natEntries;
  forwardingByTarget = builtins.seq assertNoShadowedPolicyDenies (
    builtins.listToAttrs sortedForwardingEntries
  );
}
