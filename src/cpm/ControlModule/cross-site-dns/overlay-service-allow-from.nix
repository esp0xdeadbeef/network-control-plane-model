{ lib
, helpers
, cpmData
, runtimeTargetEntries
, entryKey
, interfaceCidrsForTarget
,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  common = import ../lib/common.nix { inherit helpers; };
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;
  overlayNodeCidrs = import ./overlay-node-cidrs.nix { inherit lib helpers cpmData; };
  siteKey = enterpriseName: siteName: "${enterpriseName}|${siteName}";

  targetTenantNames =
    target:
    uniqueStrings (
      builtins.map
        (attachment: attachment.name)
        (builtins.filter
          (attachment:
          builtins.isAttrs attachment
          && (attachment.kind or null) == "tenant"
          && isNonEmptyString (attachment.name or null))
          (listOrEmpty (target.attachments or null)))
    );

  siteDataFor =
    enterpriseName: siteName:
    attrsOrEmpty ((attrsOrEmpty cpmData.${enterpriseName}).${siteName} or null);

  siteEntries =
    builtins.concatLists (
      builtins.map
        (enterpriseName:
          builtins.map
            (siteName: {
              inherit enterpriseName siteName;
              key = siteKey enterpriseName siteName;
            })
            (sortedNames (attrsOrEmpty cpmData.${enterpriseName}))
        )
        (sortedNames cpmData)
    );

  allowedRelationsForSite =
    enterpriseName: siteName:
    let contract = attrsOrEmpty ((siteDataFor enterpriseName siteName).communicationContract or null);
    in
    if builtins.isList (contract.relations or null) then
      contract.relations
    else
      listOrEmpty (contract.allowedRelations or null);

  relationsBySiteKey =
    builtins.listToAttrs (
      builtins.map
        (entry: {
          name = entry.key;
          value = allowedRelationsForSite entry.enterpriseName entry.siteName;
        })
        siteEntries
    );

  servicesBySiteKey =
    builtins.listToAttrs (
      builtins.map
        (entry: {
          name = entry.key;
          value = listOrEmpty ((siteDataFor entry.enterpriseName entry.siteName).services or null);
        })
        siteEntries
    );

  overlayNamesBySiteKey =
    builtins.listToAttrs (
      builtins.map
        (entry: {
          name = entry.key;
          value = sortedNames (attrsOrEmpty ((siteDataFor entry.enterpriseName entry.siteName).overlays or null));
        })
        siteEntries
    );

  tenantNamesForEndpoint =
    endpoint:
    let ep = attrsOrEmpty endpoint;
    in
    if endpoint == "any" then
      [ ]
    else if (ep.kind or null) == "tenant" && isNonEmptyString (ep.name or null) then
      [ ep.name ]
    else if (ep.kind or null) == "tenant-set" then
      uniqueStrings (builtins.filter isNonEmptyString (listOrEmpty (ep.members or null)))
    else
      [ ];

  externalNamesForEndpoint =
    endpoint:
    let ep = attrsOrEmpty endpoint;
    in
    if (ep.kind or null) != "external" then
      [ ]
    else
      uniqueStrings (
        lib.optional (isNonEmptyString (ep.name or null)) ep.name
        ++ builtins.filter isNonEmptyString (listOrEmpty (ep.uplinks or null))
      );

  providerEndpointAddresses =
    service:
    uniqueStrings (
      builtins.concatLists (
        builtins.map
          (endpoint:
          if builtins.isAttrs endpoint then
            listOrEmpty (endpoint.ipv4 or null) ++ listOrEmpty (endpoint.ipv6 or null)
          else if builtins.isString endpoint then
            [ endpoint ]
          else
            [ ])
          (listOrEmpty (service.providerEndpoints or null))
      )
    );

  tenantsAllowedByOverlayBySiteKey =
    builtins.listToAttrs (
      builtins.map
        (entry:
          let
            keyedTenants =
              builtins.foldl'
                (acc: relationRaw:
                  let
                    relation = attrsOrEmpty relationRaw;
                    overlayNames = externalNamesForEndpoint (relation.to or null);
                    tenantNames =
                      if (relation.action or "allow") == "allow" then
                        tenantNamesForEndpoint (relation.from or null)
                      else
                        [ ];
                  in
                  builtins.foldl'
                    (overlayAcc: overlayName:
                      overlayAcc
                      // {
                        ${overlayName} =
                          uniqueStrings ((overlayAcc.${overlayName} or [ ]) ++ tenantNames);
                      })
                    acc
                    overlayNames)
                { }
                relationsBySiteKey.${entry.key};
          in
          {
            name = entry.key;
            value = keyedTenants;
          })
        siteEntries
    );

  serviceNamesForDnsListeners =
    enterpriseName: siteName: listenAddrs:
    let
      listenSet = uniqueStrings listenAddrs;
      services = servicesBySiteKey.${siteKey enterpriseName siteName};
    in
    uniqueStrings (
      builtins.map
        (service: service.name)
        (builtins.filter
          (service:
          builtins.isAttrs service
          && isNonEmptyString (service.name or null)
          && (service.trafficType or null) == "dns"
          && lib.any (addr: builtins.elem addr listenSet) (providerEndpointAddresses service))
          services)
    );

  overlayIngressServicesForProvider =
    providerEntry: providerListeners:
    let
      serviceNames = serviceNamesForDnsListeners providerEntry.enterpriseName providerEntry.siteName providerListeners;
      relations = relationsBySiteKey.${siteKey providerEntry.enterpriseName providerEntry.siteName};
    in
    builtins.concatLists (
      builtins.map
        (relationRaw:
        let
          relation = attrsOrEmpty relationRaw;
          from = attrsOrEmpty (relation.from or null);
          to = attrsOrEmpty (relation.to or null);
        in
        if
          (relation.action or "allow") == "allow"
          && (from.kind or null) == "external"
          && (to.kind or null) == "service"
          && builtins.elem (to.name or "") serviceNames
        then
          builtins.map (overlayName: { inherit overlayName; }) (externalNamesForEndpoint from)
        else
          [ ])
        relations
    );

  tenantsAllowedToOverlay =
    enterpriseName: siteName: overlayName:
    (attrsOrEmpty (tenantsAllowedByOverlayBySiteKey.${siteKey enterpriseName siteName})).${overlayName} or [ ];

  overlayNodeCidrsByEntryKey =
    builtins.listToAttrs (
      builtins.map
        (entry:
          let
            entrySiteKey = siteKey entry.enterpriseName entry.siteName;
          in
          {
            name = entryKey entry;
            value =
              builtins.listToAttrs (
                builtins.map
                  (overlayName: {
                    name = overlayName;
                    value = overlayNodeCidrs.forTarget overlayName entry;
                  })
                  overlayNamesBySiteKey.${entrySiteKey}
              );
          })
        runtimeTargetEntries
    );

  overlayNodeCidrsByEnterprise =
    builtins.listToAttrs (
      builtins.map
        (enterpriseName:
          let
            enterpriseOverlayNames =
              uniqueStrings (
                builtins.concatLists (
                  builtins.map
                    (entry:
                      if entry.enterpriseName == enterpriseName then
                        overlayNamesBySiteKey.${siteKey entry.enterpriseName entry.siteName}
                      else
                        [ ])
                    siteEntries
                )
              );
          in
          {
            name = enterpriseName;
            value =
              builtins.listToAttrs (
                builtins.map
                  (overlayName: {
                    name = overlayName;
                    value = overlayNodeCidrs.forEnterprise enterpriseName overlayName;
                  })
                  enterpriseOverlayNames
              );
          })
        (sortedNames cpmData)
    );

  allowFromForConsumer =
    providerEntry: overlayName: consumerEntry:
    let
      allowedTenants = tenantsAllowedToOverlay consumerEntry.enterpriseName consumerEntry.siteName overlayName;
      consumerTenants = consumerEntry.tenantNames or (targetTenantNames consumerEntry.target);
      consumerDns = attrsOrEmpty ((attrsOrEmpty (consumerEntry.target.services or null)).dns or null);
      consumerUnderlayCidrs =
        if builtins.isList (consumerDns.allowFrom or null) then consumerDns.allowFrom else consumerEntry.interfaceCidrs or (interfaceCidrsForTarget consumerEntry.target);
    in
    if
      consumerEntry.enterpriseName == providerEntry.enterpriseName
      && entryKey consumerEntry != entryKey providerEntry
      && lib.any (tenantName: builtins.elem tenantName allowedTenants) consumerTenants
    then
      uniqueStrings (consumerUnderlayCidrs ++ ((overlayNodeCidrsByEntryKey.${entryKey consumerEntry}).${overlayName} or [ ]))
    else
      [ ];
in
providerEntry: providerListeners:
uniqueStrings (
  builtins.concatLists (
    builtins.map
      (overlayService:
      ((overlayNodeCidrsByEnterprise.${providerEntry.enterpriseName}).${overlayService.overlayName} or [ ])
      ++ builtins.concatLists (
        builtins.map (allowFromForConsumer providerEntry overlayService.overlayName) runtimeTargetEntries
      ))
      (overlayIngressServicesForProvider providerEntry providerListeners)
  )
)
