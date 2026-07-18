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
  localSharing = siteDns.localSharing or null;
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
    targets:
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
      allWarnings = baseWarnings ++ localWarnings;
      requesterDns = dnsFor targets requesterTargetName;
      requesterUpstreams = listOrEmpty (requesterDns.upstreamResolvers or null);
      requesterPolicies = listOrEmpty (requesterDns.requesterPolicies or null);
      requesterLocalZones = listOrEmpty (requesterDns.localZones or null);
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
        recursionMode = "local-only";
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
      // lib.optionalAttrs (requesterLocalZones != [ ]) {
        localZones = normalizedRequesterLocalZones;
      };
      providerDns = dnsFor targets authorityTargetName;
      providerAllowFrom = listOrEmpty (providerDns.allowFrom or null);
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
        reproducibilityWarnings = allWarnings;
      };
      projected = mergeDns (mergeDns targets requesterTargetName
        requesterPatch
      ) authorityTargetName providerPatch;
    in
    if allWarnings == [ ] then projected else attachWarnings targets allWarnings;
in
if !builtins.isAttrs localSharing then
  attachWarnings runtimeTargets baseWarnings
else
  applyLocalSharing runtimeTargets
