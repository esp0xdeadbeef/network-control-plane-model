{
  lib,
  common,
  enterpriseName,
  siteName,
  sitePath,
  siteDns,
  serviceDefinitions,
  allowedRelations,
  inventoryEndpoints,
}:

runtimeTargets:

let
  inherit (common) attrsOrEmpty failForwarding uniqueStrings;
  listOrEmpty = value: if builtins.isList value then value else [ ];
  localSharingRelations =
    if builtins.isList (siteDns.localSharingRelations or null) then
      siteDns.localSharingRelations
    else if builtins.isAttrs (siteDns.localSharing or null) then
      [ siteDns.localSharing ]
    else
      [ ];
  baseWarnings = listOrEmpty (siteDns.warnings or null);

  stripPrefixLength =
    value:
    if !(builtins.isString value) || value == "" then "" else builtins.head (lib.splitString "/" value);

  hostPrefix =
    value:
    let
      address = stripPrefixLength value;
    in
    if address == "" then
      null
    else
      "${address}/${if builtins.match ".*:.*" address == null then "32" else "128"}";

  service =
    serviceName:
    if builtins.hasAttr serviceName serviceDefinitions then
      serviceDefinitions.${serviceName}
    else
      failForwarding "${sitePath}.dns.localSharing" "DNS service '${serviceName}' is absent from communicationContract.services";

  providerIdentityForService =
    serviceName:
    let
      definition = service serviceName;
      providers = listOrEmpty (definition.providers or null);
    in
    if builtins.length providers == 1 then
      builtins.head providers
    else
      failForwarding "${sitePath}.dns.localSharing" "DNS service '${serviceName}' must have exactly one provider identity";

  targetAddresses =
    targetName:
    let
      realization = attrsOrEmpty (runtimeTargets.${targetName}.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (realization.interfaces or null);
      loopback = attrsOrEmpty (realization.loopback or null);
    in
    uniqueStrings (
      [
        (stripPrefixLength (loopback.addr4 or loopback.ipv4 or ""))
        (stripPrefixLength (loopback.addr6 or loopback.ipv6 or ""))
      ]
      ++ lib.concatMap (iface: [
        (stripPrefixLength (iface.addr4 or ""))
        (stripPrefixLength (iface.addr6 or ""))
      ]) (builtins.attrValues interfaces)
    );

  targetNamesForLogicalNode =
    nodeName:
    builtins.filter (
      targetName: ((runtimeTargets.${targetName}.logicalNode or { }).name or null) == nodeName
    ) (builtins.attrNames runtimeTargets);

  endpointAddressesForProvider =
    providerName:
    let
      endpoint = attrsOrEmpty (inventoryEndpoints.${providerName} or null);
    in
    uniqueStrings (listOrEmpty (endpoint.ipv4 or null) ++ listOrEmpty (endpoint.ipv6 or null));

  tenantPrefixesFor =
    tenantName:
    uniqueStrings (
      lib.concatMap
        (
          target:
          let
            realization = attrsOrEmpty (target.effectiveRuntimeRealization or null);
            interfaces = attrsOrEmpty (realization.interfaces or null);
          in
          lib.concatMap
            (
              iface:
              let
                backingRef = attrsOrEmpty (iface.backingRef or null);
              in
              if
                (iface.sourceKind or null) == "tenant"
                && (backingRef.kind or null) == "attachment"
                && (backingRef.name or null) == tenantName
              then
                builtins.filter (prefix: prefix != null) (
                  map common.ipam.canonicalNetworkPrefix [
                    (iface.addr4 or "")
                    (iface.addr6 or "")
                  ]
                )
              else
                [ ]
            )
            (builtins.attrValues interfaces)
        )
        (builtins.attrValues runtimeTargets)
    );

  targetNameForService =
    serviceName:
    let
      providerName = providerIdentityForService serviceName;
      nodeMatches = targetNamesForLogicalNode providerName;
      endpointAddresses = endpointAddressesForProvider providerName;
      endpointMatches = builtins.filter (
        targetName: lib.any (address: builtins.elem address (targetAddresses targetName)) endpointAddresses
      ) (builtins.attrNames runtimeTargets);
      matches = if builtins.length nodeMatches == 1 then nodeMatches else endpointMatches;
    in
    if builtins.length matches == 1 then
      builtins.head matches
    else
      failForwarding sitePath "DNS service '${serviceName}' provider '${providerName}' must resolve through one modeled node or endpoint";

  dnsFor =
    targets: targetName:
    attrsOrEmpty ((attrsOrEmpty (targets.${targetName}.services or null)).dns or null);

  listenerAddressesFor =
    targets: targetName: uniqueStrings (listOrEmpty ((dnsFor targets targetName).listen or null));

  serviceAddressesFor =
    targets: serviceName: targetName:
    let
      providerEndpoints = endpointAddressesForProvider (providerIdentityForService serviceName);
    in
    if providerEndpoints != [ ] then providerEndpoints else listenerAddressesFor targets targetName;

  mergeDns =
    targets: targetName: patch:
    let
      target = targets.${targetName};
      services = attrsOrEmpty (target.services or null);
      dns = attrsOrEmpty (services.dns or null);
    in
    targets
    // {
      ${targetName} = target // {
        services = services // {
          dns = dns // patch;
        };
      };
    };

  modeledLocalSharingRelationIds = uniqueStrings (
    builtins.filter
      (value: builtins.isString value && value != "")
      (map (entry: ((attrsOrEmpty (entry.relation or null)).id or null)) localSharingRelations)
  );

  unmodeledLocalAuthorityRelations = builtins.filter
    (relation:
      let
        from = attrsOrEmpty (relation.from or null);
        to = attrsOrEmpty (relation.to or null);
        relationId = relation.id or null;
        targetName =
          if
            (relation.action or "allow") == "allow"
            && (relation.trafficType or null) == "dns"
            && (from.kind or null) == "service"
            && (to.kind or null) == "service"
            && builtins.isString (to.name or null)
            && to.name != ""
            && builtins.isString relationId
            && relationId != ""
            && !(builtins.elem relationId modeledLocalSharingRelationIds)
          then
            targetNameForService to.name
          else
            null;
        targetDns = if targetName == null then { } else dnsFor runtimeTargets targetName;
      in
      targetName != null
      && builtins.isList (targetDns.localRecords or null)
      && targetDns.localRecords != [ ])
    allowedRelations;

  unmodeledLocalAuthorityWarnings = map
    (relation: {
      traceId = "FS-560-HDS-010-SDS-020-SMS-010";
      code = "DNS_LOCAL_SHARING_INTENT_MISSING";
      sourceLayer = "intent";
      requester = "service:${toString ((attrsOrEmpty relation.from).name or "<missing>")}";
      resolverService = toString ((attrsOrEmpty relation.to).name or "<missing>");
      relationId = relation.id or null;
      enterprise = enterpriseName;
      site = siteName;
      disposition = "fail-closed";
      message = "A DNS service relation targets modeled local records but has no directional local namespace-sharing intent";
    })
    unmodeledLocalAuthorityRelations;

  effectiveBaseWarnings = baseWarnings ++ unmodeledLocalAuthorityWarnings;

  warning =
    {
      code,
      requester,
      resolverService,
      candidateIds ? [ ],
      family ? null,
      context ? null,
    }:
    {
      traceId = "FS-540-HDS-010-SDS-010-SMS-020";
      inherit code requester resolverService;
      enterprise = enterpriseName;
      site = siteName;
      candidateIds = lib.sort builtins.lessThan (lib.unique candidateIds);
      disposition = "fail-closed";
    }
    // lib.optionalAttrs (family != null) { inherit family; }
    // lib.optionalAttrs (context != null) { inherit context; };

  attachWarnings =
    targets: warnings:
    builtins.mapAttrs (
      _targetName: target:
      let
        services = attrsOrEmpty (target.services or null);
      in
      if builtins.isAttrs (services.dns or null) then
        target
        // {
          services = services // {
            dns = services.dns // {
              reproducibilityWarnings = warnings;
            };
          };
        }
      else
        target
    ) targets;

  applyLocalSharing =
    targets: localSharing:
    let
      authority = attrsOrEmpty (localSharing.authority or null);
      requester = attrsOrEmpty (localSharing.requester or null);
      relation = attrsOrEmpty (localSharing.relation or null);
      providerPolicy = attrsOrEmpty (localSharing.providerPolicy or null);
      lateralPolicy = attrsOrEmpty (localSharing.lateralPolicy or null);
      lateralSource = lateralPolicy.source or null;
      authorityService = authority.service or null;
      requesterService = requester.service or null;
      relationId = relation.id or null;
      namespaces = uniqueStrings (listOrEmpty (requester.allowedNamespaces or null));
      relationMatches = builtins.filter (
        entry:
        (entry.id or null) == relationId
        && (entry.action or "allow") == "allow"
        && (entry.trafficType or null) == "dns"
      ) allowedRelations;
      authorityTargetName = targetNameForService authorityService;
      requesterTargetName = targetNameForService requesterService;
      authorityEndpoints = serviceAddressesFor targets authorityService authorityTargetName;
      requesterEndpoints = serviceAddressesFor targets requesterService requesterTargetName;
      requesterPrefixes = builtins.filter (value: value != null) (map hostPrefix requesterEndpoints);
      lateralPrefixes =
        if builtins.isString lateralSource && lateralSource != "" then
          tenantPrefixesFor lateralSource
        else
          [ ];
      missingFamilies =
        lib.optional (!lib.any (address: builtins.match ".*:.*" address == null) authorityEndpoints) "ipv4"
        ++ lib.optional (
          !lib.any (address: builtins.match ".*:.*" address != null) authorityEndpoints
        ) "ipv6";
      authorityLeak =
        (requester.recursion or false)
        || (requester.publicFallback or false)
        || (lateralPolicy.recursion or false)
        || (lateralPolicy.transitiveEgress or false)
        || (providerPolicy.action or null) != "refuse_non_local"
        || (lateralPolicy.action or null) != "refuse_non_local"
        || lateralPrefixes == [ ]
        || builtins.length relationMatches != 1;
      localWarnings =
        lib.optional authorityLeak (warning {
          code = "DNS_LOCAL_ONLY_AUTHORITY_LEAK";
          requester = "service:${toString requesterService}";
          resolverService = toString authorityService;
          candidateIds = lib.optional (builtins.isString relationId) relationId;
          context = "local-only-authority";
        })
        ++ map (
          family:
          warning {
            code = "DNS_RECURSION_FAMILY_INCOMPLETE";
            requester = "service:${toString requesterService}";
            resolverService = toString authorityService;
            candidateIds = lib.optional (builtins.isString relationId) relationId;
            inherit family;
            context = "local-namespace-provider";
          }
        ) missingFamilies;
      allWarnings = effectiveBaseWarnings ++ localWarnings;
      requesterDns = dnsFor targets requesterTargetName;
      requesterUpstreams = listOrEmpty (requesterDns.upstreamResolvers or null);
      # FS-540: recursive DNS is a relationship separate from local answer
      # authority. If the requester already carries an explicit
      # named-core-resolver upstream (its recursiveDnsIntent binding), the
      # local sharing only adds the namespace forward-zones + ACLs and must
      # keep the forwarding mode. Only resolvers without a recursive core
      # binding become local-only.
      requesterHasCoreResolver = builtins.any (
        resolver: (resolver.kind or null) == "named-core-resolver"
      ) requesterUpstreams;
      requesterPolicies = listOrEmpty (requesterDns.requesterPolicies or null);
      requesterLocalZones = listOrEmpty (requesterDns.localZones or null);
      requesterRoles = attrsOrEmpty (requesterDns.roles or null);
      requesterRecursionRole = attrsOrEmpty (requesterRoles.recursion or null);
      normalizedRequesterLocalZones = map
        (
          zone:
          if builtins.isAttrs zone && builtins.elem (zone.name or null) namespaces then
            zone // { type = "transparent"; }
          else
            zone
        )
        requesterLocalZones;
      requesterPatch = {
        forwarders = [ ];
        recursionMode = if requesterHasCoreResolver then "forwarding" else "local-only";
        outgoingInterfaces = requesterEndpoints;
        roles = requesterRoles // {
          recursion = requesterRecursionRole // {
            outgoingInterfaces = requesterEndpoints;
          };
        };
        localForwardZones = map (namespace: {
          name = namespace;
          forwardTo = authorityEndpoints;
          forwardFirst = false;
          inherit relationId;
        }) namespaces;
        upstreamResolvers = requesterUpstreams ++ [
          {
            kind = "local-namespace-authority";
            service = authorityService;
            addresses = authorityEndpoints;
            inherit namespaces relationId;
            recursion = false;
            publicFallback = false;
            transitiveEgress = false;
          }
        ];
        localOnlyPolicy = {
          providerService = authorityService;
          inherit namespaces relationId;
          recursion = false;
          publicFallback = false;
          transitiveEgress = false;
          missAction = "refuse";
        };
        requesterPolicies = requesterPolicies ++ [
          {
            requesterService = "tenant:${toString lateralSource}";
            sourcePrefixes = lateralPrefixes;
            action = "refuse_non_local";
            inherit namespaces relationId;
          }
        ];
        reproducibilityWarnings = allWarnings;
      }
      // {
        # Each shared namespace gets a transparent local-zone so the forward
        # zone below takes effect. Without this, the unbound's built-in
        # local-zone: home.arpa. static (RFC 8375) and the in-addr.arpa.
        # statics shadow the forward zone and answer NXDOMAIN locally.
        localZones = normalizedRequesterLocalZones ++ map (namespace: {
          name = namespace;
          type = "transparent";
        }) namespaces;
      };
      providerDns = dnsFor targets authorityTargetName;
      providerAllowFrom = listOrEmpty (providerDns.allowFrom or null);
      requesterDnsForRecords = dnsFor targets requesterTargetName;
      requesterLocalRecords = listOrEmpty (requesterDnsForRecords.localRecords or null);
      providerPatch = {
        allowFrom = builtins.filter (prefix: !builtins.elem prefix requesterPrefixes) providerAllowFrom;
        requesterPolicies = listOrEmpty (providerDns.requesterPolicies or null) ++ [
          {
            requesterService = requesterService;
            sourcePrefixes = requesterPrefixes;
            action = "refuse_non_local";
            inherit namespaces relationId;
          }
        ];
        # FS-560 legacy compatibility: propagate the requester's local records
        # to the authority so clients querying the authority directly (without
        # going through the forward zone) still get answers for authority-owned
        # names. The authority keeps its own records; the requester's records
        # are appended, never replacing them. Remove when the parity contract
        # stops requiring hasVlan2RuntimeLocalDns to include s-nebula-container.
        localRecords = listOrEmpty (providerDns.localRecords or null) ++ requesterLocalRecords;
        reproducibilityWarnings = allWarnings;
      };
      projected = mergeDns (mergeDns targets requesterTargetName
        requesterPatch
      ) authorityTargetName providerPatch;
    in
    if allWarnings != [ ] then attachWarnings projected allWarnings else projected;
in
if localSharingRelations == [ ] then
  attachWarnings runtimeTargets effectiveBaseWarnings
else
  builtins.foldl' applyLocalSharing runtimeTargets localSharingRelations
