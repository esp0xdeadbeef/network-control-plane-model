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
  isNonEmptyString = value: builtins.isString value && value != "";
  recursive = attrsOrEmpty (siteDns.recursive or null);
  bindings = listOrEmpty (recursive.bindings or null);
  reproducibilityWarnings = listOrEmpty (siteDns.warnings or null);
  fatalWarnings = builtins.filter (
    warning: (warning.code or null) != "DNS_CORE_UPSTREAM_HARDCODED"
  ) reproducibilityWarnings;

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

  warning =
    {
      code,
      requester,
      resolverService,
      resolverNode ? null,
      candidateIds ? [ ],
      family ? null,
      context ? null,
    }:
    {
      traceId = "FS-525-HDS-010-SDS-010-SMS-010";
      inherit code requester resolverService;
      enterprise = enterpriseName;
      site = siteName;
      candidateIds = lib.sort builtins.lessThan (lib.unique candidateIds);
      disposition = "fail-closed";
    }
    // lib.optionalAttrs (resolverNode != null) { inherit resolverNode; }
    // lib.optionalAttrs (family != null) { inherit family; }
    // lib.optionalAttrs (context != null) { inherit context; };

  targetNamesForNode =
    nodeName:
    builtins.filter (
      targetName: ((runtimeTargets.${targetName}.logicalNode or { }).name or null) == nodeName
    ) (builtins.attrNames runtimeTargets);

  targetNameForNode =
    nodeName:
    let
      matches = targetNamesForNode nodeName;
    in
    if builtins.length matches == 1 then
      builtins.head matches
    else
      failForwarding sitePath "named DNS provider '${nodeName}' must resolve to exactly one runtime target";

  endpointAddressesForProvider =
    providerName:
    let
      endpoint = attrsOrEmpty (inventoryEndpoints.${providerName} or null);
    in
    uniqueStrings (listOrEmpty (endpoint.ipv4 or null) ++ listOrEmpty (endpoint.ipv6 or null));

  service =
    serviceName:
    if builtins.hasAttr serviceName serviceDefinitions then
      serviceDefinitions.${serviceName}
    else
      failForwarding "${sitePath}.dns" "named DNS service '${serviceName}' is absent from communicationContract.services";

  providerNodeForService =
    serviceName:
    let
      definition = service serviceName;
      providers = listOrEmpty (definition.providers or null);
    in
    if builtins.isString (definition.providerNode or null) then
      definition.providerNode
    else if builtins.length providers == 1 then
      builtins.head providers
    else
      failForwarding "${sitePath}.dns" "named DNS service '${serviceName}' must have exactly one provider node";

  interfaceUplinks =
    iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (backingRef.lane or null);
    in
    uniqueStrings (
      listOrEmpty (backingRef.uplinks or null)
      ++ listOrEmpty (lane.uplinks or null)
      ++ lib.optional (builtins.isString (lane.uplink or null)) lane.uplink
    );

  dnsEgressInterfaceCandidates =
    target: selectedUplinks:
    let
      realization = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (realization.interfaces or null);
      matchesSelectedUplink =
        ifName: iface:
        let
          backingRef = attrsOrEmpty (iface.backingRef or null);
          identities = uniqueStrings (
            [
              ifName
              (backingRef.name or "")
              (iface.sourceInterface or "")
              (iface.upstream or "")
            ]
            ++ interfaceUplinks iface
          );
        in
        (iface.sourceKind or null) == "wan"
        && lib.any (uplink: builtins.elem uplink selectedUplinks) identities;
    in
    lib.filterAttrs matchesSelectedUplink interfaces;

  dnsEgressPolicyFor =
    {
      target,
      selectedUplinks,
      requester,
      resolverService,
      resolverNode,
      context,
    }:
    let
      candidates = dnsEgressInterfaceCandidates target selectedUplinks;
      candidateNames = builtins.attrNames candidates;
      selectedInterfaceName =
        if builtins.length candidateNames == 1 then builtins.head candidateNames else null;
      selectedInterface =
        if selectedInterfaceName == null then { } else candidates.${selectedInterfaceName};
      allocation = attrsOrEmpty (selectedInterface.policyRoutingAllocation or null);
      runtimeIfName = selectedInterface.runtimeIfName or selectedInterface.renderedIfName or "";
      allocationIsComplete =
        (allocation.source or null) == "control-plane-model"
        && builtins.isInt (allocation.tableId or null)
        && allocation.tableId > 0
        && builtins.isInt (allocation.tableRulePriority or null)
        && allocation.tableRulePriority > 0
        && isNonEmptyString runtimeIfName;
      warningArgs = {
        inherit
          requester
          resolverService
          resolverNode
          context
          ;
        candidateIds = uniqueStrings (selectedUplinks ++ candidateNames);
      };
      diagnostic =
        if selectedUplinks == [ ] then
          warning (warningArgs // { code = "DNS_EGRESS_SELECTION_MISSING"; })
        else if builtins.length selectedUplinks != 1 || builtins.length candidateNames > 1 then
          warning (warningArgs // { code = "DNS_EGRESS_SELECTION_AMBIGUOUS"; })
        else if builtins.length candidateNames != 1 || !allocationIsComplete then
          warning (warningArgs // { code = "DNS_EGRESS_SELECTION_MISSING"; })
        else
          null;
    in
    {
      inherit diagnostic;
      policy =
        if diagnostic != null then
          null
        else
          {
            source = "control-plane-model";
            selectedUplink = builtins.head selectedUplinks;
            selectedInterface = selectedInterfaceName;
            inherit runtimeIfName;
            tableId = allocation.tableId;
            rulePriority = allocation.tableRulePriority;
            # The mark is model-owned and intentionally equals the selected
            # policy table. Renderers consume it; they do not allocate it.
            firewallMark = allocation.tableId;
          };
    };

  relationEndpointFor =
    {
      targetName,
      families,
      selectedUplinks,
      requesterService,
      resolverService,
      resolverNode,
      relationId,
    }:
    let
      realization = attrsOrEmpty (runtimeTargets.${targetName}.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (realization.interfaces or null);
      candidates = builtins.filter (
        iface:
        (iface.sourceKind or null) == "p2p"
        && lib.any (uplink: builtins.elem uplink selectedUplinks) (interfaceUplinks iface)
      ) (builtins.attrValues interfaces);
      attachmentIds = uniqueStrings (
        map (iface: (attrsOrEmpty (iface.backingRef or null)).id or "") candidates
      );
      addresses = uniqueStrings (
        lib.concatMap (
          iface:
          let
            ipv4 = stripPrefixLength (iface.addr4 or "");
            ipv6 = stripPrefixLength (iface.addr6 or "");
          in
          lib.optional (builtins.elem "ipv4" families && ipv4 != "") ipv4
          ++ lib.optional (builtins.elem "ipv6" families && ipv6 != "") ipv6
        ) candidates
      );
      missingFamilies =
        lib.optional (
          builtins.elem "ipv4" families
          && !lib.any (address: builtins.match ".*:.*" address == null) addresses
        ) "ipv4"
        ++ lib.optional (
          builtins.elem "ipv6" families
          && !lib.any (address: builtins.match ".*:.*" address != null) addresses
        ) "ipv6";
      commonWarningArgs = {
        requester = "service:${requesterService}";
        inherit resolverService resolverNode;
        candidateIds = attachmentIds;
        context = relationId;
      };
      endpointWarning =
        if builtins.length attachmentIds != 1 then
          warning (commonWarningArgs // { code = "DNS_CORE_ENDPOINT_PATH_MISMATCH"; })
        else if missingFamilies != [ ] then
          warning (
            commonWarningArgs
            // {
              code = "DNS_CORE_FAMILY_INCOMPLETE";
              family = builtins.concatStringsSep "," missingFamilies;
            }
          )
        else
          null;
    in
    {
      inherit addresses attachmentIds endpointWarning;
      attachmentId = if builtins.length attachmentIds == 1 then builtins.head attachmentIds else null;
      ipv4 = builtins.filter (address: builtins.match ".*:.*" address == null) addresses;
      ipv6 = builtins.filter (address: builtins.match ".*:.*" address != null) addresses;
    };

  tenantAddresses =
    targetName:
    let
      interfaces = attrsOrEmpty (
        (attrsOrEmpty (runtimeTargets.${targetName}.effectiveRuntimeRealization or null)).interfaces or null
      );
      tenantInterfaces = builtins.filter (iface: (iface.sourceKind or null) == "tenant") (
        builtins.attrValues interfaces
      );
    in
    uniqueStrings (
      lib.concatMap (iface: [
        (stripPrefixLength (iface.addr4 or ""))
        (stripPrefixLength (iface.addr6 or ""))
      ]) tenantInterfaces
    );

  tenantPrefixesFor =
    tenantName:
    uniqueStrings (
      lib.concatMap (
        target:
        let
          interfaces = attrsOrEmpty (
            (attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null
          );
        in
        lib.concatMap (
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
        ) (builtins.attrValues interfaces)
      ) (builtins.attrValues runtimeTargets)
    );

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

  requesterTargetNameForService =
    serviceName:
    let
      definition = service serviceName;
      providers = listOrEmpty (definition.providers or null);
      providerName =
        if builtins.length providers == 1 then
          builtins.head providers
        else
          failForwarding "${sitePath}.dns" "named DNS requester service '${serviceName}' must have exactly one provider identity";
      nodeMatches = targetNamesForNode providerName;
      endpointAddresses = endpointAddressesForProvider providerName;
      endpointMatches = builtins.filter (
        targetName: lib.any (address: builtins.elem address (targetAddresses targetName)) endpointAddresses
      ) (builtins.attrNames runtimeTargets);
      matches = if builtins.length nodeMatches == 1 then nodeMatches else endpointMatches;
    in
    if builtins.length matches == 1 then
      builtins.head matches
    else
      failForwarding sitePath "named DNS requester service '${serviceName}' provider '${providerName}' must resolve through one modeled node or endpoint";

  egressUplinksFor =
    serviceName:
    uniqueStrings (
      lib.concatMap (
        relation:
        let
          from = attrsOrEmpty (relation.from or null);
          to = attrsOrEmpty (relation.to or null);
        in
        if
          (relation.action or "allow") == "allow"
          && (relation.trafficType or null) == "dns"
          && (from.kind or null) == "service"
          && (from.name or null) == serviceName
          && (to.kind or null) == "external"
        then
          listOrEmpty (to.uplinks or null)
        else
          [ ]
      ) allowedRelations
    );

  directTenantRequesterPrefixesFor =
    coreServiceName:
    uniqueStrings (
      lib.concatMap (
        relation:
        let
          from = attrsOrEmpty (relation.from or null);
          to = attrsOrEmpty (relation.to or null);
        in
        if
          (relation.action or "allow") == "allow"
          && (relation.trafficType or null) == "dns"
          && (from.kind or null) == "tenant"
          && (to.kind or null) == "service"
          && (to.name or null) == coreServiceName
        then
          tenantPrefixesFor (from.name or "")
        else
          [ ]
      ) allowedRelations
    );

  bindingRequesterHostPrefixesFor =
    coreServiceName:
    uniqueStrings (
      lib.concatMap (
        binding:
        let
          upstream = attrsOrEmpty (binding.upstreamResolver or null);
          advertised = attrsOrEmpty (binding.advertisedResolver or null);
        in
        if (upstream.name or null) == coreServiceName then
          let
            requesterTargetName = requesterTargetNameForService (advertised.name or null);
            requesterSources = tenantAddresses requesterTargetName;
          in
          builtins.filter (value: value != null) (map hostPrefix requesterSources)
        else
          [ ]
      ) bindings
    );

  requesterAllowFromFor =
    coreServiceName:
    uniqueStrings (
      bindingRequesterHostPrefixesFor coreServiceName
    );

  requesterRelationsFor =
    requesterServiceName:
    builtins.filter (
      relation:
      let
        from = attrsOrEmpty (relation.from or null);
        to = attrsOrEmpty (relation.to or null);
      in
      (relation.action or "allow") == "allow"
      && (relation.trafficType or null) == "dns"
      && (from.kind or null) == "tenant"
      && (to.kind or null) == "service"
      && (to.name or null) == requesterServiceName
    ) allowedRelations;

  bindRequesterInterfaces =
    {
      target,
      binding,
      requesterServiceName,
      coreServiceName,
      relationId,
      families,
    }:
    let
      realization = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (realization.interfaces or null);
      requesterRelations = requesterRelationsFor requesterServiceName;
      requesterTenantNames = uniqueStrings (
        map (relation: (attrsOrEmpty (relation.from or null)).name or "") requesterRelations
      );
      requesterRelationIds = uniqueStrings (map (relation: relation.id or "") requesterRelations);
      resolverAuthority = {
        resolver4 = if builtins.elem "ipv4" families then "127.0.0.1" else null;
        resolver6 = if builtins.elem "ipv6" families then "::1" else null;
        resolverSource = binding.resolverSource or "local-recursive";
        authoritySource = "named-dns-binding";
        inherit
          requesterServiceName
          coreServiceName
          relationId
          requesterRelationIds
          ;
      };
      bindInterface =
        _ifName: iface:
        let
          backingRef = attrsOrEmpty (iface.backingRef or null);
          isRequesterTenant =
            (iface.sourceKind or null) == "tenant"
            && (backingRef.kind or null) == "attachment"
            && builtins.elem (backingRef.name or "") requesterTenantNames;
        in
        if isRequesterTenant then iface // { dnsResolver = resolverAuthority; } else iface;
    in
    target
    // {
      effectiveRuntimeRealization = realization // {
        interfaces = builtins.mapAttrs bindInterface interfaces;
      };
    };

  mergeDns =
    target: patch:
    let
      services = attrsOrEmpty (target.services or null);
      dns = attrsOrEmpty (services.dns or null);
    in
    target
    // {
      services = services // {
        dns = dns // patch;
      };
    };

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
              reproducibilityWarnings = lib.unique (
                listOrEmpty (services.dns.reproducibilityWarnings or null) ++ warnings
              );
            };
          };
        }
      else
        target
    ) targets;

  applyBinding =
    targets: binding:
    let
      upstream = attrsOrEmpty (binding.upstreamResolver or null);
      advertised = attrsOrEmpty (binding.advertisedResolver or null);
      coreServiceName = upstream.name or null;
      requesterServiceName = advertised.name or null;
      coreNodeName = upstream.node or (providerNodeForService coreServiceName);
      coreTargetName = targetNameForNode coreNodeName;
      requesterTargetName = requesterTargetNameForService requesterServiceName;
      families = listOrEmpty (binding.allowedAddressFamilies or null);
      selectedUplinks = uniqueStrings (
        listOrEmpty ((attrsOrEmpty (binding.egressSurface or null)).uplinks or null)
      );
      matchingRelations = builtins.filter (
        relation:
        let
          from = attrsOrEmpty (relation.from or null);
          to = attrsOrEmpty (relation.to or null);
        in
        (relation.action or "allow") == "allow"
        && (relation.trafficType or null) == "dns"
        && (from.kind or null) == "service"
        && (from.name or null) == requesterServiceName
        && (to.kind or null) == "service"
        && (to.name or null) == coreServiceName
      ) allowedRelations;
      relationIds = uniqueStrings (map (relation: relation.id or "") matchingRelations);
      relationId =
        if builtins.length relationIds == 1 then
          builtins.head relationIds
        else
          "unresolved-named-dns-relation";
      relationEndpoint = relationEndpointFor {
        targetName = coreTargetName;
        inherit families selectedUplinks relationId;
        requesterService = requesterServiceName;
        resolverService = coreServiceName;
        resolverNode = coreNodeName;
      };
      endpoints = relationEndpoint.addresses;
      requesterSources = tenantAddresses requesterTargetName;
      uplinks = egressUplinksFor coreServiceName;
      accessTarget = targets.${requesterTargetName};
      accessDns = attrsOrEmpty ((attrsOrEmpty (accessTarget.services or null)).dns or null);
      accessRoles = attrsOrEmpty (accessDns.roles or null);
      accessRecursion = attrsOrEmpty (accessRoles.recursion or null);
      coreTarget = targets.${coreTargetName};
      coreDns = attrsOrEmpty ((attrsOrEmpty (coreTarget.services or null)).dns or null);
      coreRoles = attrsOrEmpty (coreDns.roles or null);
      coreRecursion = attrsOrEmpty (coreRoles.recursion or null);
      egressPolicy = dnsEgressPolicyFor {
        target = coreTarget;
        selectedUplinks = uplinks;
        requester = "service:${coreServiceName}";
        resolverService = coreServiceName;
        resolverNode = coreNodeName;
        context = relationId;
      };
      sourcePrefixes = builtins.filter (value: value != null) (
        map (
          address:
          let
            prefix = hostPrefix address;
          in
          if prefix == null then
            null
          else
            {
              family = if builtins.match ".*:.*" address == null then 4 else 6;
              inherit prefix;
            }
        ) endpoints
      );
      preferredSources =
        lib.optionalAttrs (builtins.any (address: builtins.match ".*:.*" address == null) endpoints) {
          ipv4 = builtins.head (builtins.filter (address: builtins.match ".*:.*" address == null) endpoints);
        }
        // lib.optionalAttrs (builtins.any (address: builtins.match ".*:.*" address != null) endpoints) {
          ipv6 = builtins.head (builtins.filter (address: builtins.match ".*:.*" address != null) endpoints);
        };
      boundAccess = bindRequesterInterfaces {
        target = mergeDns accessTarget {
          forwarders = endpoints;
          recursionMode = "forwarding";
          outgoingInterfaces = requesterSources;
          upstreamResolvers = [
            {
              kind = "named-core-resolver";
              service = coreServiceName;
              node = coreNodeName;
              addresses = endpoints;
              addressAuthority = "model-allocated-service-prefix";
              endpointAuthority = {
                inherit relationId;
                terminalAttachmentId = relationEndpoint.attachmentId;
              };
              returnBehavior = binding.returnBehavior or "symmetric";
            }
          ];
          roles = accessRoles // {
            recursion = accessRecursion // {
              outgoingInterfaces = requesterSources;
            };
          };
          coreResolverBinding = binding;
        };
        inherit
          binding
          requesterServiceName
          coreServiceName
          relationId
          families
          ;
      };
      boundCoreBase = mergeDns coreTarget {
        listen = endpoints;
        allowFrom = requesterAllowFromFor coreServiceName;
        forwarders = [ ];
        outgoingInterfaces = [ ];
        recursionMode = (service coreServiceName).recursionMode or "iterative";
        egress = { inherit uplinks; };
        roles = coreRoles // {
          recursion = coreRecursion // {
            outgoingInterfaces = [ ];
          };
        };
        serviceEndpointBindings = listOrEmpty (coreDns.serviceEndpointBindings or null) ++ [
          {
            service = coreServiceName;
            requesterService = requesterServiceName;
            providerNode = coreNodeName;
            inherit relationId;
            terminalAttachmentId = relationEndpoint.attachmentId;
            inherit (relationEndpoint) addresses ipv4 ipv6;
          }
        ];
      };
      boundCore = boundCoreBase // {
        runtimeOriginEgress = {
          enabled = true;
          source = "dns-service";
          policyRoutingRequired = true;
          inherit preferredSources sourcePrefixes uplinks;
          policyRouting = egressPolicy.policy;
        };
      };
    in
    if relationEndpoint.endpointWarning != null then
      attachWarnings targets [ relationEndpoint.endpointWarning ]
    else if egressPolicy.diagnostic != null then
      attachWarnings targets [ egressPolicy.diagnostic ]
    else
      targets
      // {
        ${requesterTargetName} = boundAccess;
        ${coreTargetName} = boundCore;
      };
  boundRuntimeTargets = builtins.foldl' applyBinding runtimeTargets bindings;
in
attachWarnings (
  if fatalWarnings == [ ] then boundRuntimeTargets else runtimeTargets
) reproducibilityWarnings
