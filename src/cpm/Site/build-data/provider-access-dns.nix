{ lib
, helpers
, common
, inventoryAttrs
, enterpriseName
, siteName
, siteId
, siteDisplayName
, serviceDefinitions
,
}:

let
  inherit (helpers) isNonEmptyString requireString sortedNames;
  inherit (common) attrsOrEmpty failInventory uniqueStrings;

  controlPlane = attrsOrEmpty (inventoryAttrs.controlPlane or null);
  providerAccess = attrsOrEmpty (controlPlane.providerAccess or null);
  scenarios = attrsOrEmpty (providerAccess.scenarios or null);

  serviceProviderNames =
    uniqueStrings (
      lib.concatMap
        (serviceName:
          let service = attrsOrEmpty (serviceDefinitions.${serviceName} or null);
          in if builtins.isList (service.providers or null) then builtins.filter builtins.isString service.providers else [ ])
        (sortedNames serviceDefinitions)
    );

  siteAliases = uniqueStrings [
    enterpriseName
    siteName
    siteId
    siteDisplayName
    "${enterpriseName}.${siteName}"
  ];

  scenarioSiteAliases = scenario:
    uniqueStrings [
      (scenario.site or "")
      ((attrsOrEmpty (scenario.customer or null)).site or "")
    ];

  scenarioMatchesSite = scenario:
    let
      aliases = scenarioSiteAliases scenario;
      aliasMatchesSite = lib.any (alias: builtins.elem alias siteAliases) aliases;
      aliasMatchesProviderName =
        lib.any
          (alias:
            isNonEmptyString alias
            && lib.any
              (providerName: providerName == alias || lib.hasPrefix "${alias}-" providerName)
              serviceProviderNames)
          aliases;
    in
    aliasMatchesSite || aliasMatchesProviderName;

  normalizeFollowSourceScenario = scenarioName:
    let
      scenarioPath = "inventory.controlPlane.providerAccess.scenarios.${scenarioName}";
      scenario = attrsOrEmpty scenarios.${scenarioName};
      dns = attrsOrEmpty (scenario.dns or null);
      resolver = attrsOrEmpty (dns.resolver or null);
      followSource = (dns.followSource or false) == true;
      upstreamSource = resolver.upstreamSource or null;
      customer = attrsOrEmpty (scenario.customer or null);
      provider = attrsOrEmpty (scenario.provider or null);
      publicFacing = attrsOrEmpty (scenario.publicFacing or null);
      ipv4 = attrsOrEmpty (publicFacing.ipv4 or null);
      dst =
        if isNonEmptyString (ipv4.providerAddress or null) then
          requireString "${scenarioPath}.publicFacing.ipv4.providerAddress" ipv4.providerAddress
        else
          "follow-source";
      _upstreamSource =
        if !followSource || upstreamSource == "follow-source" then
          true
        else
          failInventory
            "${scenarioPath}.dns.resolver.upstreamSource"
            "provider-access DNS followSource requires resolver.upstreamSource = \"follow-source\" before CPM handoff";
      _resolver =
        if !followSource || builtins.isAttrs (dns.resolver or null) then
          true
        else
          failInventory
            "${scenarioPath}.dns.resolver"
            "provider-access DNS followSource requires an explicit resolver source record before CPM handoff";
      # GAMP: FS-540-HDS-010-SDS-010-SMS-025 — killswitch bypass detection
      # When the DNS killswitch is enabled (FS-550), follow-source DNS records
      # must not circumvent the killswitch by routing through provider uplinks.
      killswitchBlock = (dns.killswitch or false) == true;
      _killswitchBypass =
        if !followSource || !killswitchBlock then
          true
        else
          failInventory
            "${scenarioPath}.dns.killswitch"
            "provider-access DNS followSource must not bypass killswitch policy (FS-550); set dns.killswitch=false or remove dns.followSource before CPM handoff";
    in
    if followSource && scenarioMatchesSite scenario then
      builtins.seq _upstreamSource (
        builtins.seq _resolver (
          builtins.seq _killswitchBypass {
          kind = "provider-access-dns-upstream";
          source = "provider-access-dns";
          inherit dst upstreamSource;
          scenario = scenarioName;
          scenarioId = scenario.scenarioId or null;
          gampId = scenario.gampId or null;
          customerSite = customer.site or null;
          providerRole = provider.role or null;
          resolverConsumer = resolver.consumer or null;
          implementationClass = resolver.implementationClass or null;
          failClosed = true;
          fallbackToCustomerResolver = false;
        }
      )
    )
    else
      null;

  followSourceRecords =
    builtins.filter
      (record: record != null)
      (builtins.map normalizeFollowSourceScenario (sortedNames scenarios));

  recordsForRelation = relation:
    let
      relationAttrs = attrsOrEmpty relation;
      to = attrsOrEmpty (relationAttrs.to or null);
      uplinks =
        if builtins.isList (to.uplinks or null) then builtins.filter builtins.isString to.uplinks
        else if isNonEmptyString (to.name or null) then [ to.name ]
        else [ ];
      relationId =
        if isNonEmptyString (relationAttrs.id or null) then relationAttrs.id
        else if isNonEmptyString (relationAttrs.name or null) then relationAttrs.name
        else null;
    in
    builtins.map
      (record:
        record
        // {
          inherit relationId uplinks;
        })
      followSourceRecords;
in
{
  inherit followSourceRecords recordsForRelation;
}
