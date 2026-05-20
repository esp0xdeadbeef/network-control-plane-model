{ lib
, helpers
, cpmData
, runtimeTargetEntries
, entryKey
, dnsListenersForTarget
, interfaceCidrsForTarget
,
}:

let
  inherit (helpers) isNonEmptyString;
  common = import ../lib/common.nix { inherit helpers; };
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

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

  allowedRelationsForSite =
    enterpriseName: siteName:
    let contract = attrsOrEmpty ((siteDataFor enterpriseName siteName).communicationContract or null);
    in
    if builtins.isList (contract.relations or null) then
      contract.relations
    else
      listOrEmpty (contract.allowedRelations or null);

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

  serviceNamesForDnsListeners =
    enterpriseName: siteName: listenAddrs:
    let
      listenSet = uniqueStrings listenAddrs;
      services = listOrEmpty ((siteDataFor enterpriseName siteName).services or null);
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
      relations = allowedRelationsForSite providerEntry.enterpriseName providerEntry.siteName;
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
    uniqueStrings (
      builtins.concatLists (
        builtins.map
          (relationRaw:
          let
            relation = attrsOrEmpty relationRaw;
            toExternalNames = externalNamesForEndpoint (relation.to or null);
          in
          if (relation.action or "allow") == "allow" && builtins.elem overlayName toExternalNames then
            tenantNamesForEndpoint (relation.from or null)
          else
            [ ])
          (allowedRelationsForSite enterpriseName siteName)
      )
    );

  allowFromForConsumer =
    providerEntry: overlayName: consumerEntry:
    let
      allowedTenants = tenantsAllowedToOverlay consumerEntry.enterpriseName consumerEntry.siteName overlayName;
      consumerTenants = targetTenantNames consumerEntry.target;
      consumerDns = attrsOrEmpty ((attrsOrEmpty (consumerEntry.target.services or null)).dns or null);
    in
    if
      consumerEntry.enterpriseName == providerEntry.enterpriseName
      && entryKey consumerEntry != entryKey providerEntry
      && lib.any (tenantName: builtins.elem tenantName allowedTenants) consumerTenants
    then
      if builtins.isList (consumerDns.allowFrom or null) then consumerDns.allowFrom else interfaceCidrsForTarget consumerEntry.target
    else
      [ ];
in
providerEntry: providerListeners:
uniqueStrings (
  builtins.concatLists (
    builtins.map
      (overlayService:
      builtins.concatLists (
        builtins.map (allowFromForConsumer providerEntry overlayService.overlayName) runtimeTargetEntries
      ))
      (overlayIngressServicesForProvider providerEntry providerListeners)
  )
)
